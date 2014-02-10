### Zabbix template for Intel/LSI/Symbios RAID Controllers

[Topic](https://www.zabbix.com/forum/showthread.php?t=41439) on zabbix forum

#### Available items:
**Adapter**
- Adapter model
- Firmware version
**Battery Backup Unit**
- BBU State (+trigger)
- BBU State of charge (+trigger)
- BBU manufacture date (disabled by default)
- BBU design capacity (disabled by default)
- BBU current capacity (disabled by default)
**Physical drives**
- Firmware state (+trigger)
- Predictive errors (+trigger)
- Media errors (+trigger)
- Size
* Model
**Logical volumes**
- Volume state (+trigger)
- Volume size

#### Scripts
3 scripts are available for windows (powershell) and unix (perl) servers

##### RAID Discovery script
This script is used for Low Level Discovery of RAID configuration. Scripts uses zabbix_sender and agent configuration file to report RAID configuration to zabbix.
##### RAID checks script
This script is used by zabbix agent to check "non critical" items, such as adapter model, physical drive size, etc. But this script also supports checking of all items from template (i.e. you can change type for all items from 'Zabbix trapper' to 'Zabbix Agent'). I've created "trapper" version of this script, because zabbix agent very often reports that some item is not supported (I noticed that problem only on Windows servers). Probably there are some locking occurs, when zabbix agent checks a lot of items at the same time.
##### RAID "trapper" check script
This scrips reports all values for "critical" items at once. Currently it reports BBU state and state of charge, physical drives state, predictive and media erros, logical volumes states. All other checks are performed by zabbix agent using RAID checks scripts and userparameters.

Discovery and "trapper" scripts are executed by system scheduler.

Agent userparameters:
```
# windows
UserParameter=hw.raid.physical_disk[*],C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File "C:\Program Files\zabbix_agent\raid_check.ps1" -mode pdisk -item $4 -adapter $1 -enc $2 -pdisk $3
UserParameter=hw.raid.logical_disk[*],C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File "C:\Program Files\zabbix_agent\raid_check.ps1" -mode vdisk -item $3 -adapter $1 -vdisk $2
UserParameter=hw.raid.bbu[*],C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File "C:\Program Files\zabbix_agent\raid_check.ps1" -mode bbu -item $2 -adapter $1
UserParameter=hw.raid.adapter[*],C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File "C:\Program Files\zabbix_agent\raid_check.ps1" -mode adapter -item $2 -adapter $1
# unix
UserParameter=hw.raid.physical_disk[*],/usr/bin/perl -w /etc/zabbix/scripts/raid_check.pl -mode pdisk -item $4 -adapter $1 -enclosure $2 -pdisk $3
UserParameter=hw.raid.logical_disk[*],/usr/bin/perl -w /etc/zabbix/scripts/raid_check.pl -mode vdisk -item $3 -adapter $1 -vdisk $2
UserParameter=hw.raid.bbu[*],/usr/bin/perl -w /etc/zabbix/scripts/raid_check.pl -mode bbu -item $2 -adapter $1
UserParameter=hw.raid.adapter[*],/usr/bin/perl -w /etc/zabbix/scripts/raid_check.pl -mode adapter -item $2 -adapter $1
```

for agents on unix servers RAID tool should be executed via sudo, add this to sudoers file:
```
Defaults:zabbix !requiretty
# path to your tool can be different
zabbix  ALL=NOPASSWD:/opt/MegaRAID/CmdTool2/CmdTool2
```

I'm not a programmer, so code review will be appreciated :)