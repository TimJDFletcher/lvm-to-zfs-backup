# LVM to ZFS backup

Script that snapshots and rsync the file system from an LVM Volume Group.

## Getting Started

Clone the code to somewhere on your system, I use /etc/zfsbackups

### Prerequisites

* LVM storage enabled
* rsync installed
* A backup target not in your LVM VG, preferred to be ZFS with auto snapshots

### Installing

Clone the code

```
sudo git clone https://github.com/TimJDFletcher/lvm-to-zfs-backup.git /etc/zfsbakups
```

Edit configuration to match your setup

```
sudo cp /etc/zfsbackups/zfs-backup.conf.example /etc/zfsbackups/zfs-backup.conf
sudo vim /etc/zfsbackups/zfs-backup.conf
```

Test the backup works

```
sudo /etc/zfsbackups/zfs-backup.sh
```

Enable cron based backups

```
sudo ln -s /etc/zfsbackups/zfsbackups.cron /etc/cron.d/zfsbackups
```

Enable log rotation

```
sudo ln -s /etc/zfsbackups/zfsbackups.logrotate /etc/logrotate.d/zfsbackups
```

## Deployment

The script was originally written to auto mount an external zpool and backup an LVM array
to the external drive.

This code is still in the git history but is not longer used.

This code only creates an rsync based clone of mounted filesystems from the LVM volume group.

Maintaining long term archives of these snapshots is a problem for the reader, 
I use [zfs auto-snapshot](https://github.com/zfsonlinux/zfs-auto-snapshot)

## Excluding Files

Create a file with the name ${VG}-${LV}.excludes and use standard rsync exclude patterns.

There is an [example](rsync.excludes) config file in the repo

## Authors

* **Tim Fletcher**

## License

This project is licensed under the GPL v3.0 License - see the [LICENSE.md](LICENSE.md) file for details

## Acknowledgments

* Inspiration from zfs auto snapshot