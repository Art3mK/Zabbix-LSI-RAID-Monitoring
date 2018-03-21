#!/usr/bin/perl -w

use strict;
use warnings;

my $cli             = '/opt/MegaRAID/CmdTool2/CmdTool2';
my $zabbix_config   = '/etc/zabbix_agentd.conf';
my $zabbix_sender   = '/usr/bin/zabbix_sender';
my $tmp_path        = '/tmp/raid-discovery-zsend-trapper-data.tmp';
my %enclosures      = ();

my $adp_count   = `$cli -AdpCount -NoLog`;
# Controller Count: 1.
if ($adp_count =~ m/.*Controller\sCount:\s(\d)\.*/i) {
    $adp_count = $1;
} else {
    print "Didn't find any adapter, check regex or $cli\n";
    exit(1);
}

unlink $tmp_path if (-e $tmp_path);

for (my $adapter = 0; $adapter < $adp_count; $adapter++) {
    my $pd_num = `$cli -pdGetNum -a $adapter -NoLog`;
    # Number of Physical Drives on Adapter 0: 6
    if ($pd_num =~ m/.*Number\sof\sPhysical\sDrives\son\sAdapter\s$adapter:\s(\d+)\n.*/) {
        $pd_num = $1;
        if ($pd_num == 0) {
            print "No physical disks found on adapter $adapter\n";
            next;
        }
    }

    my $number_of_lds = `$cli -LDGetNum -a $adapter -NoLog`;
    # Number of Virtual Drives Configured on Adapter 0: 3
    if ($number_of_lds=~ m/.*Number\sof\sVirtual\sDrives\sConfigured\son\sAdapter\s$adapter:\s(\d+)/) {
        $number_of_lds = $1;
        if ($number_of_lds == 0) {
            print "No virtual disks found on adapter $adapter\n";
            next;
        }
    }

    open(ZSEND_FILE,">>$tmp_path") or die "Can't open $tmp_path: $!";

    my $bbu_info = `$cli -AdpBbuCmd -GetBbuStatus -a $adapter -NoLog`;
    if (!($bbu_info =~ m/.*Get BBU Status Failed.*/)) {
        my @bbu_data = `$cli -AdpBBUCMD -a $adapter -NoLog`;

        foreach my $line (@bbu_data) {
            if ($line =~ m/Battery State\s*:\s(.*)$/) {
                my $bbu_state = 1;
                $bbu_state = 0 if ($1 =~ m/^(Optimal|Operational)$/);
                print ZSEND_FILE "- hw.raid.bbu[$adapter,\"bbu_state\"] \"$bbu_state\"\n";
            } elsif (($line =~ m/(?:Relative|Absolute)\sState\sof\sCharge\s*:\s(\d+).*%/i)) {
                my $state_of_charge = $1;
                print ZSEND_FILE "- hw.raid.bbu[$adapter,\"state_of_charge\"] \"$state_of_charge\"\n";
            } else {
                next;
            }
        }
    }

    my @vd_list = `$cli -LDinfo -Lall -a $adapter -NoLog`;
    my $check_next_line = -1;
    my $vdrive_id       = -1;
    foreach my $line (@vd_list) {
        if ($line =~ m/^\s*Virtual\sDrive:\s(\d+)\s.*$/) {
            $vdrive_id  = $1;
            $check_next_line = 1;
        } elsif (($line =~ m/^\s*State\s+:\s(.*)$/) && ($check_next_line != -1) && ($vdrive_id != -1)) {
            my $state = 1;
            $state = 0 if ($1 =~ m/^Optimal$/);
            print ZSEND_FILE "- hw.raid.logical_disk[$adapter,$vdrive_id,\"vd_state\"] \"$state\"\n";
            $check_next_line = -1;
            $vdrive_id       = -1;
        } else {
            next;
        }
    }

    my @pd_list = `$cli -pdlist -a $adapter -NoLog`;
    $check_next_line = 0;
    my $enclosure_id    = -1;
    my $drive_id        = -1;
    # Determine Slot Number for each drive on current enclosure
    foreach my $line (@pd_list) {
        if ($line =~ m/^Enclosure\sDevice\sID:\s(\d+)$/) {
            $enclosure_id           = $1;
            $check_next_line        = 1;
        } if ($line =~ m/^Enclosure\sDevice\sID:\sN\/A$/) {
            # This can happen, if embedded raid controller is in use, there are drives and logical disks, but no enclosures
            $enclosure_id           = 2989; # 0xBAD, :( magic hack
            $check_next_line        = 1;
        } elsif (($line =~ m/^Slot\sNumber:\s(\d+)$/) && $check_next_line && ($enclosure_id != -1)) {
            $drive_id               = $1;
            $check_next_line        = 1;
        } elsif (($line =~ m/^Media Error Count:\s(.*)/) && $check_next_line && ($drive_id != -1)) {
            my $media_errors        = $1;
            print ZSEND_FILE        "- hw.raid.physical_disk[$adapter,$enclosure_id,$drive_id,\"media_errors\"] \"$media_errors\"\n";
            $check_next_line        = 1;
        } elsif (($line =~ m/^Predictive Failure Count:\s(.*)/) && $check_next_line && ($drive_id != -1)) {
            my $predictive_errors   = $1;
            print ZSEND_FILE        "- hw.raid.physical_disk[$adapter,$enclosure_id,$drive_id,\"predictive_errors\"] \"$predictive_errors\"\n";
            $check_next_line        = 1;
        } elsif (($line =~ m/^Firmware state:\s(.*)/) && $check_next_line && ($drive_id != -1)) {
            my $firmware_state      = 1;
            $firmware_state         = 0 if ($1 =~ m/^(Unconfigured\(good\).*|Online,\sSpun.*|Hotspare,\sSpun.*)$/);
            print ZSEND_FILE        "- hw.raid.physical_disk[$adapter,$enclosure_id,$drive_id,\"firmware_state\"] \"$firmware_state\"\n";
            $check_next_line        = 0;
            $drive_id               = -1;
            $enclosure_id           = -1;
        } else {
            next;
        }
    }
    close (ZSEND_FILE) or die "Can't close $tmp_path: $!";
}

my @cmd_args = ($zabbix_sender,'-c',$zabbix_config,'-i',$tmp_path);
system(@cmd_args);
