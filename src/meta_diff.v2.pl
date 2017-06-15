#!/usr/bin/perl
#-------------------------------------------------+
#    [APM] This script was generated by amp.pl    |
#    [APM] Created time: 2016-06-07 15:04:41      |
#-------------------------------------------------+
# name: meta_diff.pl
# func: 1. do two group Different Analysis for taxon of 16S using metastats 
#       2. do multi group Different Analysis for taxon of 16S using LEFse.
# version: 2.0
#--------------------------------------------------
# update
# version 2.0
# 1. add method Anosim and Adonis
# 2. refer to 1 vs multi in metastat, will use the mean val of multi samples group (1 vs 1)
# 3. add the sample vs sample diff analysis with metastat

use strict;
use warnings;

use Getopt::Std;
use List::Util qw/sum/;
use Cwd 'abs_path';
use FindBin qw($Bin);

use lib "$Bin/../lib";
use General qw/timeLOG/;
use CONF;
use DEBUG;

my %opts = (o=>".",r=>"qsub",c=>1);
getopts('mlr:o:c:',\%opts);

&usage unless @ARGV == 2;
my ($conf_file,$profile) = @ARGV;

# check the options 
unless ($opts{m} || $opts{l})
{
	print STDERR "FATA ERROR: you must select one method to execute different analysis\n";
	&usage;
}

# turn outdir to full path 
$opts{o} = abs_path($opts{o});

# read the config file 
my $conf = load_conf($conf_file,-check=>1,-init=>1);
my %groups = fetch_group_samples($conf);
my %samples = map {$_ => 1} split /[;,\s\t]/ , $conf->{samples};
timeLOG("read the config done ...");

#-------------------------------------------------------------------------------
# set the software path 
#-------------------------------------------------------------------------------
my $Rscript      = check_path($conf->{soft}->{rscript});
my $metastat     = check_path($conf->{soft}->{metastat});
my $lefse_bin    = check_path($conf->{soft}->{lefse_bin});
my $qsubsge      = check_path($conf->{soft}->{'qsub-sge'});
my $multiprocess = check_path($conf->{soft}->{multiprocess});
my $python       = check_path($conf->{soft}->{python});
#-------------------------------------------------------------------------------

# read the profile file 
my ($abundance,$relative_abundance) = read_profile($profile);
timeLOG("read the profile done ...");

#-------------------------------------------------------------------------------
#  main 
#-------------------------------------------------------------------------------
mkdir $opts{o} unless -d $opts{o};

#-------------------------------------------------------------------------------
#  metastats 
#-------------------------------------------------------------------------------
if ($opts{m})
{
	ERROR("FATA ERROR: 'two_groups_diff' attribute was no defined in the config file, please check!") unless ($conf->{metastats_groups_diff});
	my @groups = split /,/,$conf->{two_groups_diff};

	mkdir "$opts{o}/metastat" unless -d "$opts{o}/metastats";
	my @levels = keys %$abundance;
	
	open SH , ">$opts{o}/metastat/metastat.sh" or die $!;

	foreach my$vs (@groups)
	{
		my ($group1,$group2) = split /\&/,$vs;
		my (@samples1,@samples2,@samples);
		
		if ($groups{$group1} && $groups{$group2})
		{
			@samples1 = @{$groups{$group1}};
			@samples2 = @{$groups{$group2}};
			@samples = (@samples1,@samples2);
		}
		elsif ($samples{$group1} && $samples{$group2})
		{
			@samples1 = ($group1);
			@samples2 = ($group2);
			@samples  = ($group1,$group2);
		}
		else 
		{
			ERROR("group [$group1] is not defined in the config file!") unless $groups{$group1};
			ERROR("group [$group2] is not defined in the config file!") unless $groups{$group2};
			exit 1;
		}
		
		# 1 vs more is not supported by Metastats, use the mean val replaced
		my $flag = ( ($#samples1==0 && $#samples2>0) || ($#samples1>0 && $#samples2==0) ) ? 1 : 0;
		WARN("1 vs more is not supported by Metastats, use the mean val replaced (1 vs 1), [$vs]") if ($flag);

		# the group split order for metastat
		my $split = $flag ? 2 : scalar @samples1 + 1;

		$vs =~ s/&/-VS-/;
		foreach my$level (@levels)
		{
			next if ($level eq "Domain"); # slip the domain level

			my $outdir = "$opts{o}/metastat/$level";
			mkdir $outdir unless -d $outdir;
			open OUT , ">$outdir/$vs.metastat.xls" or die $!;
			my $header = $flag ? qq($level\t${ [ join "\t",($group1,$group2) ] }[0]\n) : qq($level\t${ [ join "\t",@samples ] }[0]\n);
			print OUT $header;
			
			my $count = 0;
			foreach my$taxon (keys %{$$abundance{$level}})
			{
				my @values = map { $$abundance{$level}{$taxon}{$_} } @samples;
				my $sum = sum(@values);
				next if (0 == $sum);
				
				if ($flag)
				{
					my @values1 = map { $$abundance{$level}{$taxon}{$_} } @samples1;
					my @values2 = map { $$abundance{$level}{$taxon}{$_} } @samples2;
					my $val1 = int sum(@values1)/($#samples1+1);
					my $val2 = int sum(@values2)/($#samples2+1);
					print OUT qq($taxon\t${[join "\t",($val1,$val2)]}[0]\n);
				}
				else 
				{
					print OUT qq($taxon\t${[join "\t",@values]}[0]\n);
				}
				$count ++;
			}
			close OUT;
			
			if ($count < 2)
			{
				WARN("the number of taxonomy is less than 2, skip, [$vs:$level]");
				next;
			}

			my $out_header = "$level\tMean($group1%)\tvariance($group1%)\tstd.err($group1%)\tMean($group2%)\tvariance($group2%)\tstd.err($group2%)\tP-value\tFDR";
			print SH "$Rscript $metastat $outdir/$vs.metastat.xls $outdir/$vs.metastat.xls.tmp $split; ";
			print SH "sort -k9n $outdir/$vs.metastat.xls.tmp > $outdir/$vs.metastat.result.xls; ";
			print SH "sed -i -r 1i'$out_header' $outdir/$vs.metastat.result.xls; rm -f $outdir/$vs.metastat.xls.tmp \n";
		}
	}
	
	close SH;

	run_shell("$opts{o}/metastat/metastat.sh",$opts{c},-run=>$opts{r});
	timeLOG("metastat was done :)");
}


#-------------------------------------------------------------------------------
#  LEFse
#-------------------------------------------------------------------------------
if ($opts{l})
{
	if (! $conf->{lefse_groups_diff})
	{
		WARN("WARN: 'multi_groups_diff' attribute was no defined in the config file, please check!");
		return;
	}

	my @vses = split /,/,$conf->{lefse_groups_diff};

	mkdir "$opts{o}/LefSe" unless -d "$opts{o}/LefSe";
	
	open SH , ">$opts{o}/LefSe/LefSe.sh" or die $!;
	
	print SH <<CMD;
#-----------------------------------
# config the env for LefSe 
export R_HOME=/Bio/R/lib64/R/ 
export R_LIBS=\$R_HOME/library/ 
export LD_LIBRARY_PATH=\$R_HOME/lib:\$LD_LIBRARY_PATH 
export PATH=\$R_HOME/bin:\$PATH
#-----------------------------------

CMD

	OUTER:foreach my$vs (@vses)
	{
		# fetch the groups and samples information
		my @groups = split /&/,$vs;
		my @samples;
		my @groups_list;

		INNER:foreach my $group (@groups)
		{
			ERROR("group [$group] is not defined in the config file!") unless $groups{$group};

			my @tmp = @{$groups{$group}};

			if ($#tmp < 2)
			{
				WARN("the sample num of group [$group] is less than 3 which is at least number for LefSe analysis, skip [$vs] ...");
				next OUTER;
			}
			
			@samples = (@samples,@tmp);
			
			@tmp = map { $group } 0 .. $#tmp;
			@groups_list = (@groups_list,@tmp);
		}
		
		$vs =~ s/&/\-vs\-/g;
		
		# create the input relative abundance matrix for LefSe
		open OUT,">$opts{o}/LefSe/$vs.Lefse.xls" or die $!;
		
		print OUT qq(Group\t${[ join "\t",@groups_list ]}[0]\n);
		print OUT qq(level\t${[ join "\t",@samples ]}[0]\n);

		foreach my $taxon (keys %$relative_abundance)
		{
			next if ($taxon eq "NA");
			
			my @values = map { $$relative_abundance{$taxon}{$_}/100 } @samples;
			my $sum = sum(@values);
			next if (0 == $sum);

			print OUT qq($taxon\t${[join "\t",@values]}[0]\n);
		}
		close OUT;
	
		# create the run shell 
		print SH "#---------LefSe for $vs---------\n";
		print SH "$python $lefse_bin/format_input.py $opts{o}/LefSe/$vs.Lefse.xls $opts{o}/LefSe/$vs.Lefse.in -c 1 -s 2 -o 1000000; \n";
		print SH "$python $lefse_bin/run_lefse.py $opts{o}/LefSe/$vs.Lefse.in $opts{o}/LefSe/$vs.Lefse.res -f 0.9; \n";
		print SH "$python $lefse_bin/plot_res.py $opts{o}/LefSe/$vs.Lefse.res $opts{o}/LefSe/$vs.Lefse.svg --format svg; \n";
		print SH "$python $lefse_bin/plot_cladogram.py $opts{o}/LefSe/$vs.Lefse.res $opts{o}/LefSe/$vs.Lefse.cladogram.svg --format svg --labeled_stop_lev 7 --abrv_stop_lev 7 --min_point_size 0.5 --max_point_size 3 --radial_start_lev 1; \n";
		print SH "mkdir $opts{o}/LefSe/$vs; \n";
		print SH "/usr/bin/rsvg-convert -d 300 -p 300  $opts{o}/LefSe/$vs.Lefse.svg -o $opts{o}/LefSe/$vs.Lefse.png; \n";
		print SH "/usr/bin/rsvg-convert -d 300 -p 300 $opts{o}/LefSe/$vs.Lefse.cladogram.svg -o $opts{o}/LefSe/$vs.Lefse.cladogram.png;\n";
		print SH "$python $lefse_bin/plot_features.py $opts{o}/LefSe/$vs.Lefse.in $opts{o}/LefSe/$vs.Lefse.res $opts{o}/LefSe/$vs/;\n\n";
	}

	close SH;
	
	#run_shell("$opts{o}/LefSe/LefSe.sh",1,-run=>$opts{r});
	timeLOG("the script of LefSe was created, please run it by yourself in the head node.");
}

#===============================================================================
# Sub Functions
#-------------------------------------------------------------------------------
# read the otu profile file 
#-------------------------------------------------------------------------------
sub read_profile
{
	my $file = shift;
	
	my %abundance;
	my %relative_abundance;

	my @samples = split /[;,\s\t]/ , $conf->{samples};
	my $sample_num = scalar @samples;
	
	open IN,$file or die $!;
	
	# check the samples 
	my $header = <IN>;
	chomp $header;
	
	my ($flag,$total,@tmp) = split /\t/,$header;
	die "FATA ERROR: your samples number in profile file is not equal to the samples number defined in the config file!\n" 
		if ( ($#tmp+1-7)/2 != $sample_num );

	#@samples = @tmp[$sample_num .. $sample_num*2-1];
	my @levels = @tmp[-7 .. -1];
	
	while(<IN>)
	{
		my @tmp = split /\t/;

		my $otuid = shift @tmp;
		my $total = shift @tmp;
		my @abundance = @tmp[0 .. $sample_num-1];
		my @relative_abundance = @tmp[$sample_num .. $sample_num*2-1];
		
		my @taxons = @tmp[-7 .. -1];
		chomp $taxons[-1];
		
		# save the relative abundance of full taxonomy for LefSe
		foreach my $j ( 0 .. $#samples )
		{
			my @tmp = grep { $_ ne "" } @taxons;
			
			foreach (0 .. $#tmp)
			{
				my $taxon = join "|" , @tmp[0 .. $_];
				$relative_abundance{$taxon}{$samples[$j]} += $relative_abundance[$j];
			}
		}

		# re define the taxon, add prefix level NA taxon, like:
		# Genus is BacteroidesBacteroides, Species is unknown, than set Species is 'BacteroidesBacteroides_NA'
		foreach my$i (1 .. $#levels)
		{
			if ($taxons[$i] eq "" && $taxons[$i-1] !~ /NA$/)
			{
				$taxons[$i] = $taxons[$i-1] . "_NA";
			}
			elsif ($taxons[$i] eq "")
			{
				$taxons[$i] = "NA";
			}
		}

		foreach my$i (0 .. $#levels)
		{
			foreach my$j (0 .. $#samples)
			{
				$abundance{$levels[$i]}{$taxons[$i]}{$samples[$j]} += $abundance[$j];
			}
		}
	}
	close IN;
	
	return (\%abundance,\%relative_abundance);
}

#-------------------------------------------------------------------------------
# run the shell 
sub run_shell
{
	my ($shell,$cpu,%opts) = @_;
	my $queue = $opts{'-queue'} || "all.q";
	my $mem = $opts{'-mem'} || 2;
	$opts{'-run'} ||= "qsub";

	my $cmd;
	if ($opts{'-run'} eq "multi" && $cpu > 1)
	{
		$cmd = "perl $multiprocess -cpu $cpu $shell";
	}
	elsif ($opts{'-run'} eq "multi" && $cpu == 1)
	{
		$cmd = "sh $shell 1>$shell.log 2>$shell.err";
	}
	elsif ($opts{'-run'} eq "qsub" && $cpu == 1)
	{
		$cmd = "qsub -cwd -S /bin/sh -sync y -q $queue $shell";
	}
	elsif ($opts{'-run'} eq "qsub")
	{
		$cmd = "perl $qsubsge --queue=$queue --convert no --resource vf=${mem}G --maxjob $cpu $shell";
	}
	else 
	{
		ERROR("Your -run set is error, either be 'multi' or 'qsub'");
	}

	timeLOG("create shell file, [$shell], runing ... ");
	timeLOG("CMD: $cmd");
	system($cmd);
}

sub usage
{
	print <<HELP;
Usage:   perl $0 [options] <config file> <taxa profile file>

Options: -m        do two group Different Analysis for taxon of 16S using metastats
         -l        do multi group Different Analysis for taxon of 16S using LEFse
         -r STR    shell run type, multi(run local) or qsub (qsub to compute nodes), [qsub]
         -c INT    set the cpu number, [1]
         -o STR    output directory, [.]
HELP
	exit;
}
