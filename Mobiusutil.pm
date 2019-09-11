#!/usr/bin/perl
#
# Mobiusutil.pm
# 
# Requires:
# DBhandler.pm
# Loghandler.pm
# Encode
# utf8
# 
# This is a simple utility class that provides some common functions
#
# Blake Graham-Henderson 
# MOBIUS
# blake@mobiusconsortium.org
# 2014-2-22


package Mobiusutil;
 use Loghandler;
 use Data::Dumper;
 use DateTime;
 use Encode;
 use utf8;
 
sub new
{
    my $class = shift;
    my $self = {};
    bless $self, $class;
    return $self;
}


sub readConfFile
 {
	my %ret = ();
	my $ret = \%ret;
	my $file = @_[1];
	
	my $confFile = new Loghandler($file);
	if(!$confFile->fileExists())
	{
		print "Config File does not exist\n";
		undef $confFile;
		return false;
	}

	my @lines = @{ $confFile->readFile() };
	undef $confFile;
	
	foreach my $line (@lines)
	{
		$line =~ s/\n//;  #remove newline characters
		my $cur = trim('',$line);
		my $len = length($cur);
		if($len>0)
		{
			if(substr($cur,0,1)ne"#")
			{
		
				my $Name, $Value;
				($Name, $Value) = split (/=/, $cur);
				$$ret{trim('',$Name)} = trim('',$Value);
			}
		}
	}
	
	return \%ret;
 }
 
sub makeEvenWidth  #line, width
{
	my $ret;
	
	if($#_+1 !=3)
	{
		return;
	}
	$line = @_[1];	
	$width = @_[2];
	#print "I got \"$line\" and width $width\n";
	$ret=$line;
	if(length($line)>=$width)
	{
		$ret=substr($ret,0,$width);
	} 
	else
	{
		while(length($ret)<$width)
		{
			$ret=$ret." ";
		}
	}
	#print "Returning \"$ret\"\nWidth: ".length($ret)."\n";
	return $ret;
	
}

 sub trim
{
	my $self = shift;
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

sub is_integer 
{
   defined @_[1] && @_[1] =~ /^[+-]?\d+$/;
}

1;

