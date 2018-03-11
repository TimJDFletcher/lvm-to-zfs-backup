#!/bin/bash -e
. /etc/zfsbackups/zfs-backup.conf

if [ $(id -u) -gt 0 ] ; then
    echo $0 needs to be run as root
    exit 1
fi

vglock()
{
    if [ -f $lockfile ] ; then
        echo $lockfile found, bailing out
        logger ZFS backup aborted, lock file found
        break
    else
        logger ZFS backup started
        touch $lockfile
    fi
}

vgunlock()
{
    if [ -f $lockfile ] ; then
        rm $lockfile
    fi
}

vgbackup()
{
    backupdir=$backupfs/$vg
    # Find and backup all volumes in the volume group
    echo "Backing up volume group $vg"
    mkdir -p $snapshot_mountpoint/$date
    for volume in $(lvm lvs --noheadings -o lv_name $vg) ; do
        if mount | grep -q "^/dev/mapper/${vg}-${volume} "; then
            echo "$volume"
            # Take an LVM snapshot 10% of the size of the origin volume
            lvm lvcreate --quiet --extents 10%ORIGIN --chunksize 512k --snapshot --name ${volume}.${date} /dev/${vg}/${volume}
            blockdev --setro /dev/${vg}/${volume}.${date}
            mkdir -p $snapshot_mountpoint/$date/$volume
            if [ -f $conf_dir/${vg}-${volume}.excludes ] ; then
                rsyncargs="${rsyncargs_base} --delete-excluded --exclude-from=$conf_dir/${vg}-${volume}.excludes"
            else
                rsyncargs="${rsyncargs_base}"
            fi
            # Actually backup files
            if mount -o ro /dev/${vg}/${volume}.${date} $snapshot_mountpoint/$date/$volume ; then
                mkdir -p /$backupdir/$volume/
                $rsync_cmd $rsyncargs $snapshot_mountpoint/$date/$volume/ /$backupdir/$volume/
                umount $snapshot_mountpoint/$date/$volume
            else
                echo "$volume snapshot failed to mount skipping backup"
            fi
            sync ; sleep 10
            if ! lvm lvremove --quiet --force ${vg}/${volume}.${date} ; then
                echo lvremove failed, sleeping 30 seconds and using dmsetup
                sync ; sleep 30
                dmsetup remove ${vg}-${volume}-real
                dmsetup remove ${vg}-${volume}.${date}
                lvm lvremove --quiet --force ${vg}/${volume}.${date}
            fi
            rmdir $snapshot_mountpoint/$date/$volume
        else
            echo "$volume not mounted skipping backup"
        fi
    done
    rmdir $snapshot_mountpoint/$date
    echo done
}

mountpointbackup()
{
    echo -n "$(basename $mountpoint), "
    if grep -q " $mountpoint " /proc/mounts ; then
        if [ "x/" = "x$mountpoint" ] ; then
            safename=root
        else
            safename=$(echo $mountpoint | sed -e s,^/,,g -e s,/,.,g )
        fi

        mkdir -p $snapshot_mountpoint/$date/$safename
        if mount -o ro,bind $mountpoint $snapshot_mountpoint/$date/$safename ; then
            $rsync_cmd $rsyncargs $snapshot_mountpoint/$date/$safename/ /$backupdir/$safename/
            umount $snapshot_mountpoint/$date/$safename
        fi
        rmdir $snapshot_mountpoint/$date/$safename
    fi
    rmdir $snapshot_mountpoint/$date
}

echo "Backing up volume groups"
for vg in $vgs ; do
    lockfile=$lockdir/${vg}.zfsbackup
    vglock
    vgbackup
    vgunlock
done

echo -n "Backing up other filesystems: "
backupdir=$backupfs
for mountpoint in $extramountpoints ; do
    mountpointbackup
done
echo done

if [ x$libvirtbackup = xtrue ] ; then
    echo "Backing up libvirt disk images"
    backupdir=$backupfs
    libvirtbackup
fi

logger ZFS backup completed
