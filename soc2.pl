#!/usr/bin/perl
# ---------------------------------------------------------------
# Copyright © 2019 MOBIUS
# Blake Graham-Henderson <blake@mobiusconsortium.org>
# Ted Peterson <ted@mobiusconsortium.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# ---------------------------------------------------------------


use strict;
use warnings;
use lib qw(../);
use Loghandler;
use DBhandler;
use Mobiusutil;
use Data::Dumper;
use email;
use DateTime;
use utf8;
use Encode;
use DateTime;
use DateTime::Format::Duration;
use Getopt::Long;
use JSON;


my $configFile = $ARGV[0];
our $debug=0;
our $reportonly=0;
our $reset=0;
our $runClean=0;
our $storeRAW=1;
our $storeReport=1;
our $jobid=-1;
our $log;
our $dbHandler;
our @reportFiles =();
our %conf;
our $lynis_reports_path;
our $aide_reports_path;
our $mobUtil = new Mobiusutil();
our $dateString = "";
our $dt;
our $fdate;
our $ftime;

GetOptions (
"config=s" => \$configFile,
"job=i" => \$jobid,
"reset" => \$reset,
"reportonly" => \$reportonly,
"debug" => \$debug
)
or die("Error in command line arguments\nYou can specify
--config configfilename                       [Path to the config file - required]
--debug flag                                  [Cause more logging output]
--reset flag                                  [Empty out the schema table]
--reportonly flag                             [Skip everything and only run a report - Reports are always run at the end]
--job integer                                 [Usually used in conjunction with reportonly. It will spit out the report for that job. Last job is default]
\n");

 if(!$configFile)
 {
    print "Please specify a config file\n";
    exit;
 }

my $conf = $mobUtil->readConfFile($configFile);



# Define our types of reports and the functions in this program used to consume the data
our %reportTypes = (
'lynis' => 'lynis_reports_path',
'aide' => 'aide_reports_path'
);

our %reportFunctions = (
'lynis' => 'consumeLynis',
'aide' => 'consumeAIDE'
);

 if($conf)
 {
    %conf = %{$conf};

    # $soc2_reports_path = $conf{"soc2_reports_path"};
    $lynis_reports_path = $conf{"lynis_reports_path"};
    $aide_reports_path = $conf{"aide_reports_path"};

    if ($conf{"logfile"})
    {
        $dt = DateTime->now(time_zone => "local");
        $fdate = $dt->ymd;
        $ftime = $dt->hms;
        $dateString = "$fdate $ftime";
        $log = new Loghandler($conf->{"logfile"});
        $log->truncFile("");
        $log->addLogLine(" ---------------- Script Starting ---------------- ");
        print "Executing job  tail the log for information (".$conf{"logfile"}.")\n";
        my @reqs = ("logfile", "dbhost","db","dbuser","dbpass","port");
        my $valid = 1;
        my $errorMessage="";
        for my $i (0..$#reqs)
        {
            if(!$conf{$reqs[$i]})
            {
                $log->addLogLine("Required configuration missing from conf file");
                $log->addLogLine($reqs[$i]." required");
                $valid = 0;
            }
        }
        if($valid)
        {
            my %dbconf;
            $dbconf{'db'} = $conf{"db"};
            $dbconf{'dbhost'} = $conf{"dbhost"};
            $dbconf{'dbuser'} = $conf{"dbuser"};
            $dbconf{'dbpass'} = $conf{"dbpass"};
            $dbconf{'port'} = $conf{"port"};

            $dbHandler = new DBhandler($dbconf{"db"},$dbconf{"dbhost"},$dbconf{"dbuser"},$dbconf{"dbpass"},$dbconf{"port"});

            setupSchema($dbHandler);

            if(!$reportonly)
            {
                while ((my $internal, my $mvalue ) = each(%reportTypes))
                {
                    my @files;
                    my $dirPath = $conf{$mvalue};
                    if(! -d $dirPath)
                    {
                        print "Cannot find path to $internal\n$mvalue does not exist!";
                        exit 1;
                    }
                    #Get all files in the directory path
                    @files = @{dirtrav(\@files,$conf{$mvalue})};
                    $jobid = createNewJob('Starting') if ( ($#files > -1) && ($jobid == -1) );

                    foreach(@files)
                    {
                        next if ($_ =~ m/for_humans/);
                        my $file = $_;
                        my $exec = $reportFunctions{$internal} . "(\"$file\", \"$internal\");";
                        updateJob("Processing","Working on file $file with function call $exec");
                        eval($exec);
                    }
                }
            }

            elsif($jobid == -1)
            {
                $jobid = @{getPrevJobID()}[0];
                print "Sorry, there is only one job in the database and two are required for reports\n" if(!$jobid);
                exit if(!$jobid);
            }

            my $reportOutput = runReports();

            updateJob("Completed","");
        }
        $log->addLogLine(" ---------------- Script Ending ---------------- ");
    }
    else
    {
        print "Config file does not define 'logfile'\n";
    }
 }

sub runReports
{
    my @lastJob = @{getPrevJobID()};
    my $lastID = @lastJob[0];
    if( $lastID && ($lastID != -1) ) ## There was a previous job (catching the case where this is the FIRST job ever)
    {
        my $lastDate = @lastJob[1];
        updateJob("Executing reports and email","");
        my %serverDictionary = ();
        my $importantReportName = "Servers Appearance / Disappearance";
        my $wholeServerChanges;
        my $queriesRan = "";

        #################################
        #
        # Server presence
        #
        #################################
        my $reportName = "Server presence changed";
        # Make sure All of the same servers are here this time
        my $query = "
        select *
        from
        (select ss.id as server_id,ss.name,count(*)
        from
        soc2.server ss,
        soc2.report sr
        where
        ss.id=sr.sid and
        sr.job = $jobid
        group by 1,2
        ) as this_job full join
        (
        select ss.id as server_id,ss.name,count(*)
        from
        soc2.server ss,
        soc2.report sr
        where
        ss.id=sr.sid and
        sr.job = $lastID
        group by 1,2
        ) as last_job on this_job.server_id = last_job.server_id
        where
        last_job.server_id is null or
        this_job.server_id is null
        ";
        updateJob("Running query",$query);
        my @results = @{$dbHandler->query($query)};
        if ($#results > -1)
        {
            my $itemsBefore = "";
            my $itemsNow = "";
            $wholeServerChanges = "";
            foreach(@results)
            {
                my @row = @{$_};
                $itemsNow.=$row[1]."\n" if( defined($row[1]) && length($row[1]) > 0 ); ## Handle the case where there is a new server compared to last time
                $itemsBefore.=$row[4]."\n" if(defined($row[4])); ## Handle the case where there is a new server compared to last time
            }
            my @s = ();
            $serverDictionary{$importantReportName}{$importantReportName}{"herenow"} = \@s if ( (!$serverDictionary{"Servers Appearance / Disappearance"}{"Servers Appearance / Disappearance"}{"herenow"}) && (length($itemsNow) > 0) );
            my @s2 = ();
            $serverDictionary{$importantReportName}{$importantReportName}{"notherenow"} = \@s2 if ( (!$serverDictionary{"Servers Appearance / Disappearance"}{"Servers Appearance / Disappearance"}{"herenow"}) && (length($itemsBefore) > 0) );
            $wholeServerChanges = "" . $itemsNow . $itemsBefore;
            push ($serverDictionary{$importantReportName}{$importantReportName}{"herenow"}, $itemsNow) if(length($itemsNow) > 0);
            push ($serverDictionary{$importantReportName}{$importantReportName}{"notherenow"}, $itemsBefore) if(length($itemsBefore) > 0);
            $queriesRan .= "\n\n$reportName\n$query";
        }


        #################################
        #
        # Key presence
        #
        #################################
        $reportName = "Presence";
        # Make sure All of the same keys are here this time
        $query = "
        select *
        from
        (select ss.id as server_id,ss.name,sr.key as key
        from
        soc2.server ss,
        soc2.report sr
        where
        ss.id=sr.sid and
        sr.job = $jobid
        ) as this_job full join
        (
        select ss.id as server_id,ss.name,sr.key as key
        from
        soc2.server ss,
        soc2.report sr
        where
        ss.id=sr.sid and
        sr.job = $lastID
        ) as last_job on this_job.server_id = last_job.server_id and this_job.key = last_job.key
        where
        last_job.server_id is null or
        this_job.server_id is null
        order by 2,3,5,6
        ";
        updateJob("Running query",$query);
        if ($#results > -1)
        {
            my $itemsBefore = "";
            my $itemsNow = "";
            my @results = @{$dbHandler->query($query)};
            foreach(@results)
            {
                my @row = @{$_};
                my $go = 1;
                if($wholeServerChanges)
                {
                    # Make sure we are not going to report the entire server that is missing. Don't care
                    my $check = $row[1]  if ($row[1] && length($row[1]) > 0);
                    $check = $row[4]  if ($row[4] && length($row[4]) > 0);
                    if( $wholeServerChanges =~ /\Q$check\E/) { $go = 0; }
                }
                if($go)
                {
                    my $thisServer = $row[1] || $row[4];
                    my $thisValue = $row[2] || $row[5];
                    my $thisType = $row[2] ? "herenow" : "notherenow";
                    $serverDictionary{$thisServer} = {} if !$serverDictionary{$thisServer};
                    $serverDictionary{$thisServer}{$reportName} = {} if !$serverDictionary{$thisServer}{$reportName};
                    my @s = ();
                    $serverDictionary{$thisServer}{$reportName}{$thisType} = \@s if !$serverDictionary{$thisServer}{$reportName}{$thisType};
                    push $serverDictionary{$thisServer}{$reportName}{$thisType}, $thisValue;
                    $log->addLine("$thisServer : $thisType\n" . Dumper($serverDictionary{$thisServer}{$reportName}{$thisType})) if $debug;
                }
                undef $go;
            }
            $queriesRan .= "\n\n$reportName\n$query";
        }

        #################################
        #
        # Changed Value
        #
        #################################
        $reportName = "Changed Values";
        $query = "
        select *
        from
        (select ss.id as server_id,ss.name,sr.key as key,sr.value as \"value\"
        from
        soc2.server ss,
        soc2.report sr
        where
        ss.id=sr.sid and
        sr.key !~* 'suggestion' and
        sr.key !~* 'time' and
        sr.key !~* 'kernel_ent' and
        sr.key !~* 'journal_meta_data' and
        sr.key !~* 'journal_oldest_bootdate' and
        sr.job = $jobid
        ) as this_job full join
        (
        select ss.id as server_id,ss.name,sr.key as key,sr.value as \"value\"
        from
        soc2.server ss,
        soc2.report sr
        where
        ss.id=sr.sid and
        sr.key !~* 'suggestion' and
        sr.key !~* 'time' and
        sr.key !~* 'kernel_ent' and
        sr.key !~* 'journal_meta_data' and
        sr.key !~* 'journal_oldest_bootdate' and
        sr.job = $lastID
        ) as last_job on this_job.server_id = last_job.server_id and this_job.key = last_job.key and this_job.value != last_job.value
        where
        last_job.server_id is not null and
        this_job.server_id is not null
        order by 2,3,5,6
        ";
        updateJob("Running query",$query);
        if ($#results > -1)
        {
            my $itemsBefore = "";
            my $itemsNow = "";
            my @results = @{$dbHandler->query($query)};
            foreach(@results)
            {
                my @row = @{$_};
                my $thisServer = $row[1];
                my $thisValue = "  Key: " . $row[2] . "\nBefore/After:\n" . $row[7] . "\n" . $row[3];
                my $thisType = "changed";
                $serverDictionary{$thisServer} = {} if !$serverDictionary{$thisServer};
                $serverDictionary{$thisServer}{$reportName} = {} if !$serverDictionary{$thisServer}{$reportName};
                my @s = ();
                $serverDictionary{$thisServer}{$reportName}{$thisType} = \@s if !$serverDictionary{$thisServer}{$reportName}{$thisType};
                push $serverDictionary{$thisServer}{$reportName}{$thisType}, $thisValue;
                $log->addLine("$thisServer : $thisType\n" . Dumper($serverDictionary{$thisServer}{$reportName}{$thisType})) if $debug;
            }
            $queriesRan .= "\n\n$reportName\n$query";
        }
        #################################
        #
        # Suggestions
        #
        #################################
        $reportName = "Suggestions";
        $query = "
        select ss.id as server_id,ss.name,sr.key as key,sr.value as \"value\"
        from
        soc2.server ss,
        soc2.report sr
        where
        ss.id=sr.sid and
        sr.key ~* 'suggestion' and
        sr.job = $jobid
        order by 2,3
        ";
        updateJob("Running query",$query);
        if ($#results > -1)
        {
            my $itemsBefore = "";
            my $itemsNow = "";
            my @results = @{$dbHandler->query($query)};
            foreach(@results)
            {
                my @row = @{$_};
                my $thisServer = $row[1];
                my $thisValue = $row[2] . ": " . $row[3];
                my $thisType = "suggestion";
                $serverDictionary{$thisServer} = {} if !$serverDictionary{$thisServer};
                $serverDictionary{$thisServer}{$reportName} = {} if !$serverDictionary{$thisServer}{$reportName};
                my @s = ();
                $serverDictionary{$thisServer}{$reportName}{$thisType} = \@s if !$serverDictionary{$thisServer}{$reportName}{$thisType};
                push $serverDictionary{$thisServer}{$reportName}{$thisType}, $thisValue;
                $log->addLine("$thisServer : $thisType\n" . Dumper($serverDictionary{$thisServer}{$reportName}{$thisType})) if $debug;
            }
            $queriesRan .= "\n\n$reportName\n$query";
        }

        ## alphabatize the servers
        my @serverOrder = ();
        push (@serverOrder, $_) foreach (keys %serverDictionary);
        @serverOrder = sort @serverOrder;
        ## now make sure $importantReportName gets to the top
        if($serverDictionary{$importantReportName})
        {
            my $i = 0;
            while($i < $#serverOrder)
            {
                if(@serverOrder[$i] eq $importantReportName && ($i>0) )
                {
                    my $temp = @serverOrder[$i-1];
                    @serverOrder[$i-1] = @serverOrder[$i];
                    @serverOrder[$i] = $temp;
                    $i = $i - 2;
                }
                $i++;
            }
        }

        my $suggestionEmailBody = "";
        my $mainEmailBody = "";
        foreach my $serverName (@serverOrder)
        {
            $mainEmailBody .= "\n\n" . boxText($serverName, "#", "|", 4);
            $suggestionEmailBody .= "\n\n" . boxText($serverName, "#", "|", 4) if($serverName ne $importantReportName);
            foreach my $rName (keys $serverDictionary{$serverName})
            {
                foreach my $thisType (keys $serverDictionary{$serverName}{$rName})
                {
                    my $english = "";
                    $english = "Dissappeared" if $thisType eq "notherenow";
                    $english = "Appeared" if $thisType eq "herenow";
                    $english = "Changed" if $thisType eq "changed";
                    $english = "Suggestions" if $thisType eq "suggestion";
                    $log->addLine("Decided on $english from type $thisType") if $debug;
                    my $fillvar =  $thisType eq "suggestion" ? '$suggestionEmailBody' : '$mainEmailBody';
                    $fillvar .= ' .= boxText("$rName - $english","-", "|",1);' . $fillvar .' .= "$_ \n" foreach( @{$serverDictionary{$serverName}{$rName}{$thisType}} );';
                    $log->addLine("Executing: $fillvar") if $debug;
                    eval($fillvar);
                }
            }
        }
        $mainEmailBody = "NO DIFFERENCES" if(length($mainEmailBody) == 0); ## Catching the case when nothing changed, but we should report that too!
        $mainEmailBody = boxText("Comparing $fdate to $lastDate","#", "|", 1) . $mainEmailBody;
        my @tolist = ($conf{"alwaysemail"});
        my $email = new email($conf{"fromemail"},\@tolist,1,1,\%conf);
        my $displayjobid = $jobid;
        $displayjobid = "Report Only" if $reportonly;
        my $subject = makeSubjectName($importantReportName, 50, \@serverOrder);
        $subject = "Job: $displayjobid $dateString $subject";
        $email->send($subject,$mainEmailBody.$queriesRan);
        print "$subject\n\n$mainEmailBody" if $debug;

        if(length($suggestionEmailBody)>0)
        {
            $email = new email($conf{"fromemail"},\@tolist,1,0,\%conf);
            $subject = "SUGGESTIONS: $subject";
            $suggestionEmailBody = boxText("Comparing $fdate to $lastDate","#", "|", 1) . $suggestionEmailBody;
            $email->send($subject,$suggestionEmailBody.$queriesRan);
            print "$subject\n\n$suggestionEmailBody" if $debug;
        }
    }
}

sub makeSubjectName
{
    my $ignoreName = shift;
    my $maxLength = shift;
    my @servers = @{$_[0]};
    my $ret = $conf{"subject_seed"} || "Server Audit";
    $ret .=" - ";
    my $count = 0;
    foreach(@servers)
    {
        $ret .= $_ . ',' if($_ ne $ignoreName);

        if(length($ret) > $maxLength)
        {
            $ret = substr($ret,0,-1); #remove trailing comma
            my $leftover = $#servers - $count;
            $log->addLine("total: " .$#servers . " leftover = $leftover") if $debug;
            $ret .= " and $leftover more" if $leftover > 0;
            last;
        }
        $count++;
    }

    return $ret;
}

sub boxText
{
    my $text = shift;
    my $hChar = shift;
    my $vChar = shift;
    my $padding = shift;
    my $ret = "";
    my $totalLength = length($text) + (length($vChar)*2) + ($padding *2) + 2;
    my $heightPadding = ($padding / 2 < 1) ? 1 : $padding / 2;

    # Draw the first line
    my $i = 0;
    while($i < $totalLength)
    {
        $ret.=$hChar;
        $i++;
    }
    $ret.="\n";
    # Pad down to the data line
    $i = 0;
    while( $i < $heightPadding )
    {
        $ret.="$vChar";
        my $j = length($vChar);
        while( $j < ($totalLength - (length($vChar))) )
        {
            $ret.=" ";
            $j++;
        }
        $ret.="$vChar\n";
        $i++;
    }

    # data line
    $ret.="$vChar";
    $i = -1;
    while($i < $padding )
    {
        $ret.=" ";
        $i++;
    }
    $ret.=$text;
    $i = -1;
    while($i < $padding )
    {
        $ret.=" ";
        $i++;
    }
    $ret.="$vChar\n";
    # Pad down to the last
    $i = 0;
    while( $i < $heightPadding )
    {
        $ret.="$vChar";
        my $j = length($vChar);
        while( $j < ($totalLength - (length($vChar))) )
        {
            $ret.=" ";
            $j++;
        }
        $ret.="$vChar\n";
        $i++;
    }
     # Draw the last line
    $i = 0;
    while($i < $totalLength)
    {
        $ret.=$hChar;
        $i++;
    }
    $ret.="\n";

}

sub consumeLynis
{
    my $file = shift;
    my $rtype = shift;

    my ($short, $long) = @{figureServerName($file,$rtype)};
    my $tfile = new Loghandler($file);
    my @lines = @{$tfile->readFile()};

    my $serverid = makeServer($short, $long);
    my $reportid = storeRAW(\@lines,$rtype) if $storeRAW;

    $log->addLine("
        consumeLynis
        file: $file
        storeRAW: $storeRAW
        rtype: $rtype
        short: $short
        long: $long
        serverid: $serverid
        reportid: $reportid") if ($debug);

    ## taking a gamble that it's the first line and only the first line with data.
    ## But its reliable because we wrote the ansible

    my $insertPOS = 1;
    foreach(@lines)
    {
        $log->addLine("consumeLynis: line=\n",Dumper($_)) if $debug;

        # my $insertPOS = 1;
        my @json  = @{decode_json($_)};
        $log->addLine(Dumper(@json));

        my $insertQuery = "INSERT INTO soc2.report(rid,sid,key,value,job)\n VALUES\n";
        my @insertValues = ();
        my %fullKeys = ();
        foreach (@json)
        {
            my $pair = $_;
            my @keypair = split(/=/,$pair);
            my $key = shift(@keypair);
            my $value = join('=', @keypair);
            my %finalKeyPairs = %{createKeyName($key,$value,\%fullKeys)};

            while ( (my $ikey, my $ivalue) = each(%finalKeyPairs) )
            {
                $insertQuery.="(\$" . $insertPOS++ . ",\$" . $insertPOS++ . ",\$" . $insertPOS++ . ",\$" . $insertPOS++ . ",\$" . $insertPOS++ . "),\n";
                push (@insertValues,($reportid,$serverid,$ikey,$ivalue,$jobid));
                $fullKeys{$ikey} = 1;
            }
        }

        if($insertPOS > 1)  ## There was data, we need to push it to the database
        {
            $insertQuery = substr($insertQuery, 0, -2);
            $log->addLine("consumeLynis: values=\n".Dumper(@insertValues)) if $debug;
            updateJob("consumeLynis",$insertQuery);
            $dbHandler->updateWithParameters($insertQuery,\@insertValues);
        }

        ## Only one line on these files. Might as well go last (should be the last line anyways)
        last;
    }
}

sub consumeAIDE
{
    my $file = shift;
    my $rtype = shift;

    $log->addLine("File: $file");
    my ($short, $long) = @{figureServerName($file,$rtype)};
    my $tfile = new Loghandler($file);
    my @lines = @{$tfile->readFile()};

    my $serverid = makeServer($short, $long);
    my $reportid = storeRAW(\@lines, $rtype) if $storeRAW;

    $log->addLine("
        consumeAIDE
        file: $file
        storeRAW: $storeRAW
        rtype: $rtype
        short: $short
        long: $long
        serverid: $serverid
        reportid: $reportid") if ($debug);

    my $insertQuery = "INSERT INTO soc2.report(rid,sid,key,value,job)\n VALUES\n";
    my @insertValues = ();
    my %fullKeys = ();
    my $interested = 0;
    my $sectionTitle = '';
    my $stopLine = '';
    my %sectionsUsed = ();
    my $delimiter = '';
    my $keyPos = 0;
    my $i = 0;
    my $insertPOS = 1;

    while( $lines[$i]  )
    {
        my $line = $lines[$i];
        $line =~ s/^\s+|\s+$//g;
        if($interested)
        {
            $log->addLine("STILL INTERESTED line: $line");
            if( length($line) > 0 )
            {
                if( $line =~ m/\Q$stopLine\E/g )
                {
                    $log->addLine("Stopped being interested");
                    $interested = 0;
                }
                else
                {
                    my @s = split(/\Q$delimiter\E/,$line);
                    my $additionalKey = $s[$keyPos];
                    $additionalKey =~ s/^\s+|\s+$//g;
                    my $value;
                    foreach my $j(0..$#s)
                    {
                        $value .= $s[$j] if $j != $keyPos;
                    }
                    $value =~ s/^\s+|\s+$//g;
                    my $key = getNewKeyName($sectionTitle."_".$additionalKey, \%fullKeys);
                    $log->addLine("Final Key = $key");
                    $fullKeys{$key} = 1;
                    $insertQuery.="(\$" . $insertPOS++ . ",\$" . $insertPOS++ . ",\$" . $insertPOS++ . ",\$" . $insertPOS++ . ",\$" . $insertPOS++ . "),\n";
                    push (@insertValues,($reportid,$serverid,$key,$value,$jobid))
                }
            }

        }
        else
        {
            if( (lc($line) =~ m/summary\:/g ) && !$sectionsUsed{"summary"} ) ## Summary section
            {
                $log->addLine("INTERESTED: summary");
                $interested = 1;
                $sectionTitle = "summary";
                $stopLine = "-------------------";
                $delimiter = ':';
                $keyPos = 0; ## left hand side
                $sectionsUsed{"summary"} = 1;
            }
            elsif( (lc($line) =~ m/added\s*files\:/g ) && !$sectionsUsed{"addedfiles"} )
            {
                $log->addLine("INTERESTED: addedfiles");
                $interested = 1;
                $sectionTitle = "added_files";
                $stopLine = "-------------------";
                $sectionsUsed{"addedfiles"} = 1;
                $delimiter = ':';
                $keyPos = 1; ## right hand side
                $i++; # because the very next line
            }
            elsif( (lc($line) =~ m/removed\s*files:/g ) && !$sectionsUsed{"removedfiles"} )
            {
                $log->addLine("INTERESTED: removedfiles");
                $interested = 1;
                $sectionTitle = "removed_files";
                $stopLine = "-------------------";
                $sectionsUsed{"removedfiles"} = 1;
                $delimiter = ':';
                $keyPos = 1; ## right hand side
                $i++; # because the very next line
            }
            elsif( (lc($line) =~ m/changed\s*files:/g ) && !$sectionsUsed{"changedfiles"} )
            {
                $log->addLine("INTERESTED: changedfiles");
                $interested = 1;
                $sectionTitle = "changed_files";
                $stopLine = "-------------------";
                $sectionsUsed{"changedfiles"} = 1;
                $delimiter = ':';
                $keyPos = 1; ## right hand side
                $i++; # because the very next line
            }
        }
        $i++;
    }
    if($insertPOS > 1)  ## There was data, we need to push it to the database
    {
        $insertQuery = substr($insertQuery, 0, -2);
        $log->addLine("consumeAIDE: query=\n".Dumper($insertQuery)) if $debug;
        $log->addLine("consumeeAIDE: values=\n".Dumper(@insertValues)) if $debug;
        updateJob("consumeLynis",$insertQuery);
        $dbHandler->updateWithParameters($insertQuery,\@insertValues);
    }

}

sub createKeyName
{
    my $key = shift;
    my $value = shift;
    my %dictionary = %{$_[0]};
    my %ret = ();

    $log->addLine("Incoming key:\n$key") if $debug;

    if($key =~ /[\[|\]]/)  ## These keys usually have multiple sub-keys
    {
        $key =~ s/[\[|\]]//g;  #don't care to keep those pesky brackets
        $log->addLine("Brackets") if $debug;
        if($value =~ /\|/)
        {
            my @ch = @{nonEmptyValues('|',$value)};
            $log->addLine("$#ch Pipes: value = $value") if $debug;
            my $hasEqualSigns = 0;

            foreach(@ch)
            {
                $hasEqualSigns = 1 if($_ =~ /=/);
                last if $hasEqualSigns;
            }
            if($hasEqualSigns)   ## Handle the case where the subvalues use equal signs
            {
                $log->addLine("Found equal signs") if $debug;
                ## nginx config looks like this
                ## nginx_config[]=|file=/etc/nginx/sites-enabled/osrf-ws-http-proxy|depth=2|tree=/server/location|number=2|setting=proxy_set_header|value=X-Real-IP $remote_addr|
                if($key =~ /nginx_config/)
                {
                    $log->addLine("Found nginx_config") if $debug;
                    my $accKey = $key;
                    while($#ch > 0)
                    {
                        my $append = shift @ch;
                        $append =~ s/=/_/g;
                        $accKey.="_$append";
                    }
                    my $theKey = getNewKeyName($accKey,\%dictionary);
                    $dictionary{$theKey} = 1;
                    $ret{$theKey} = $ch[0];
                }
                else
                {
                    $log->addLine("Found non nginx_config") if $debug;
                    foreach(@ch)
                    {
                        my @valuePair = split(/=/,$_);
                        my $theKey = getNewKeyName($key . "_" . $valuePair[0],\%dictionary);
                        $dictionary{$theKey} = 1;
                        $ret{$theKey} = $valuePair[1] || 1;  ## handle the case where it looks like value=|
                    }
                }
            }
            elsif( $key =~ /network_listen/ ) ## network ports are special
            {
                # string looks like network_listen[]=raw,ss,v1|tcp|127.0.0.1:2210||
                # network_listen_port[]=0.0.0.0:10000|udp|perl|
                # the last empty pipe is eliminated by nonEmptyValues
                $log->addLine("more than 2 values network_listen") if $debug;
                my $append = shift @ch;
                $append .= "_$_" foreach(@ch);
                my $theKey = getNewKeyName($key . "_" . $append,\%dictionary);
                $dictionary{$theKey} = 1;
                $ret{$theKey} = 1;
            }
            elsif( $key =~ /details/ ) ## details are inconsistently formatted
            {
                # details[]=-|nginx|field:protocol;value:tlsv1;|
                # details[]=SSH-7408|sshd|desc:sshd option AllowTcpForwarding;field:AllowTcpForwarding;prefval:NO;value:YES;|
                $log->addLine("more than 2 values details") if $debug;
                my $append = pop @ch;
                $append = pop @ch if $append eq '-'; # Handle the case where there is a minus sign at the beginning
                my $theKey = $key."_".$append;
                while( $ret{$theKey} && $#ch > 1 ) ## grow the key until it's unique
                {
                    $append = pop @ch;
                    $theKey .="_$append";
                }
                $theKey = getNewKeyName($theKey,\%dictionary);
                $dictionary{$theKey} = 1;
                $ret{$theKey} .= " $_" foreach(@ch);
            }
            elsif($#ch == 1) ## Handle the example like dev-hugepages.mount|static|
            {
                $log->addLine("Exactly two values") if $debug;
                my $theKey = getNewKeyName($key . "_" . $ch[0],\%dictionary);
                $dictionary{$theKey} = 1;
                $ret{$theKey} = $ch[1];
            }
            elsif( $#ch > 1 && $key =~ /suggestion/) ## suggestion is special
            {
                $log->addLine("more than 2 values suggestion") if $debug;
                my $append = shift @ch;
                my $theKey = getNewKeyName($key . "_" . $append,\%dictionary);
                $dictionary{$theKey} = 1;
                $ret{$theKey} .= " $_" foreach(@ch);
            }
            elsif( $#ch > 1 ) ## catch the rest in a default
            {
                $log->addLine("more than 2 values generic default") if $debug;
                my $theKey = getNewKeyName($key,\%dictionary);
                $dictionary{$theKey} = 1;
                $ret{$theKey} .= "| $_" foreach(@ch);
            }
            elsif( $#ch == 0 ) ## the singles become the key
            {
                $log->addLine("Only one values generic default") if $debug;
                my $theKey = getNewKeyName($key . "_" . $ch[0],\%dictionary);
                $dictionary{$theKey} = 1;
                $ret{$theKey} = 1;
            }
        }
        else ## Case when the key has brackets but no pipes in the value
        {
            # compiler_world_executable[]=/usr/bin/gcc-5
            # home_directory[]=/var/lib/postgresql
            $log->addLine("Brackets and no pipes") if $debug;
            my $theKey = getNewKeyName($key . "_" . $value,\%dictionary);
            $dictionary{$theKey} = 1;
            $ret{$theKey} = 1;
        }
    }
    elsif ( $key =~ m/installed_packages_array/g )  ## this is the special packages array that has a sub array
    {
        $log->addLine("installed_packages_array") if $debug;
        my @innerKeyPair = @{nonEmptyValues('|',$value)};
        foreach(@innerKeyPair)
        {
            if($_ =~ m/,/g)  ## needs to contain a comma
            {
                my @finalKeyPair = split(',',$_);
                $log->addLine(Dumper(@finalKeyPair));
                my $pacKey = shift(@finalKeyPair);
                $pacKey = getNewKeyName( "package!$pacKey", \%dictionary );
                $dictionary{$pacKey} = 1;
                $ret{$pacKey} = shift(@finalKeyPair);
            }
        }
    }
    else
    {
        $log->addLine("no brackets generic default") if $debug;
        my $fKey = getNewKeyName( $key, \%dictionary );
        $dictionary{$fKey} = 1;
        $ret{$fKey} = $value;
    }

    $log->addLine("Final keys\n". Dumper(\%ret)) if $debug;

    return \%ret;
}

sub nonEmptyValues
{
    my $delimiter = shift;
    my $value = shift;
    $log->addLine("nonEmptyValues: Splitting on $delimiter") if $debug;
    $log->addLine("nonEmptyValues: Splitting $value") if $debug;
    my @array = split(/\Q$delimiter\E/, $value);
    $log->addLine("nonEmptyValues: $#array splits") if $debug;
    my @ret = ();
    foreach(@array)
    {
        if($_)
        {
            my $t = $_;
            $t =~ s/^\s+|\s+$//g;
            $log->addLine("nonEmptyValues: working with $t") if $debug;
            push @ret, $t if length($t) > 0;
        }
    }
    return \@ret;
}

sub getNewKeyName
{
    my $newKey = shift;
    my %dictionary = %{$_[0]};
    my $ret = $newKey;
    if($dictionary{$newKey})
    {
        my $inc = 1;
        $inc++ while( $dictionary{$newKey.'_'.$inc} );
        $ret = $newKey.'_'.$inc;
    }
    return $ret;
}

sub figureServerName
{
    my $filename = shift;
    my $rtype = shift;
    my @ret = ();
    my @r = split(/\//,$filename);
    $filename = pop @r;
    if($filename =~ m/(.+)\.(.+)\.txt/)
    {

        my $domainname = "$2";
        my $shortname = "$1";
        $shortname = "$1" if ($shortname =~ m/([^\/]+)$/);
        $domainname =~ s/_/./g;
        push (@ret,($shortname, $domainname));
    }
    else
    {
        print "figureServerName CANNOT MATCH ON THE FILENAME: $filename";
    }
    $log->addLine("figureServerName: \@ret=\n".Dumper(@ret)) if $debug;
    return \@ret;
}

sub makeServer
{
    my $short = shift;
    my $long = shift;
    my $ret = getServerID($short);

    if($ret == -1) ## doesn't exist yet - let's make it
    {
        my $query = "insert into SOC2.SERVER(FQDN_OR_IP,NAME) VALUES (\$1, \$2)";
        my @values = ($long,$short);
        $dbHandler->updateWithParameters($query,\@values);
        $ret = getServerID($short);
    }
    return $ret;
}

sub getServerID
{
    my $short = shift;
    my $ret = -1;
    my $query = "select id from soc2.server where lower(name) = \$data\$$short\$data\$";
    updateJob("getServerID", $query);
    my @results = @{$dbHandler->query($query)};
    foreach(@results)
    {
        my @row = @{$_};
        $ret = $row[0];
    }
    return $ret;
}


sub storeRAW
{
    my @rawbody = @{$_[0]};
    my $jobtype = $_[1];
    my $body = join("",@rawbody);
    my $query = "insert into SOC2.REPORT_RAW(FILE,JOB,REPORT_TYPE) VALUES (\$3, \$1, \$2)";
    my @values = ($jobid,$jobtype,$body);
    updateJob("storeRAW",$query."\n".Dumper(\@values));
    $dbHandler->updateWithParameters($query,\@values);
    return getReportID();
}

sub getReportID
{
    my $ret = -1;
    my $query = "SELECT max( ID ) FROM soc2.report_raw";
    my @results = @{$dbHandler->query($query)};
    foreach(@results)
    {
        my $row = $_;
        my @row = @{$row};
        return $row[0];
    }
    return $ret;
}

sub getPrevJobID
{
    my @ret = ();
    my $query = "select max(id) from soc2.job where id != $jobid";
    my @results = @{$dbHandler->query($query)};
    foreach(@results)
    {
        my $row = $_;
        my @row = @{$row};
        push @ret, $row[0];
        # now get the rundate
        $query = "select start_time::date from soc2.job where id = " . $row[0];
        my @result = @{$dbHandler->query($query)};
        $row = @result[0];
        @row = @{$row};
        push @ret, $row[0];
    }
    return \@ret;
}

sub dirtrav
{
    my @files = @{$_[0]};
    my $pwd = $_[1];
    opendir(DIR,"$pwd") or die "Cannot open $pwd\n";
    my @thisdir = readdir(DIR);
    closedir(DIR);
    foreach my $file (@thisdir)
    {
        if(($file ne ".") and ($file ne ".."))
        {
            if (-d "$pwd/$file")
            {
                @files = @{dirtrav(\@files,"$pwd/$file")};
            }
            elsif (-f "$pwd/$file")
            {
                push(@files, "$pwd/$file");
            }
        }
    }
    return \@files;
}

sub setupSchema
{
    my $query = "DROP SCHEMA soc2 CASCADE";
    $dbHandler->update($query) if($reset);
    $query = "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'soc2'";
    my @results = @{$dbHandler->query($query)};
    if($#results==-1)
    {
        $query = "CREATE SCHEMA soc2";
        $dbHandler->update($query);

        $query = "CREATE TABLE soc2.server(
        id bigserial NOT NULL,
        name text DEFAULT ''::text,
        fqdn_or_ip text DEFAULT ''::text,
        CONSTRAINT server_pkey PRIMARY KEY (id)
        )";
        $dbHandler->update($query);

        $query = "CREATE TABLE soc2.job
        (
        id bigserial NOT NULL,
        start_time timestamp with time zone NOT NULL DEFAULT now(),
        last_update_time timestamp with time zone NOT NULL DEFAULT now(),
        status text default 'processing',
        current_action text,
        current_action_num bigint default 0,
        CONSTRAINT job_pkey PRIMARY KEY (id)
          )";
        $dbHandler->update($query);

        $query = "CREATE TABLE soc2.report_raw(
        id bigserial NOT NULL,
        report_type text DEFAULT ''::text,
        file text DEFAULT ''::text,
        job bigint NOT NULL,
        create_date timestamp NOT NULL DEFAULT now(),
        CONSTRAINT report_raw_pkey PRIMARY KEY (id),
        foreign key (job) references soc2.job(id) ON DELETE CASCADE
        )";
        $dbHandler->update($query);

        $query = "CREATE TABLE soc2.report(
        id bigserial NOT NULL,
        job bigint NOT NULL,
        rid integer,
        sid integer NOT NULL,
        key text DEFAULT ''::text,
        value text DEFAULT ''::text,
        CONSTRAINT report_pkey PRIMARY KEY (id),
        foreign key (job) references soc2.job(id) ON DELETE CASCADE,
        foreign key (rid) references soc2.report_raw(id) ON DELETE CASCADE,
        foreign key (sid) references soc2.server(id) ON DELETE CASCADE
        )";
        $dbHandler->update($query);
    }
}

sub createNewJob
{
    my $status = $_[0];
    my $query = "INSERT INTO soc2.job(status) values('$status')";
    my $results = $dbHandler->update($query);
    if($results)
    {
        $query = "SELECT max( ID ) FROM soc2.job";
        my @results = @{$dbHandler->query($query)};
        foreach(@results)
        {
            my $row = $_;
            my @row = @{$row};
            $jobid = $row[0];
            return $jobid;
        }
    }
    return -1;
}

sub updateJob
{
    my $status = $_[0];
    my $action = $_[1];
    $log->addLine($action);
    my $query = "UPDATE soc2.job SET last_update_time=now(),status=\$\$$status\$\$, CURRENT_ACTION_NUM = CURRENT_ACTION_NUM+1,current_action=\$1 where id=$jobid";
    my @values = ($action);
    my $results = $dbHandler->updateWithParameters($query,\@values);
    return $results;
}

 exit;
