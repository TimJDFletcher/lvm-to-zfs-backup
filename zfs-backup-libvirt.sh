#!/bin/sh
. /etc/zfsbackups/zfs-backup.conf

if [ $(id -u) -gt 0 ] ; then
    echo $0 needs to be run as root
    exit 1
fi

if ! zfs-control.sh start ; then
    echo Failed to start ZFS pool, bailing out
    logger Failed to start ZFS pool, backup aborted
    exit 1
fi

# Could be expanded to read storage locations out of libvirt
libvirtbackup()
{
    runningDomains=$(virsh list --all --state-running | egrep '^ [0-9]|^ -' | awk '{print $2}')
    mountpoint=$(df /var/lib/libvirt/images | tail -n 1 | awk '{print $6}')

    if [ "x/" = "x$mountpoint" ] ; then
        safename=root
    else
        safename=$(echo $mountpoint | sed -e s,^/,,g -e s,/,.,g )
    fi

    for domain in $runningDomains ; do
        echo Hot backing up $domain
        virsh domblklist --details $domain |  egrep '^file[[:space:]]*disk' | awk '{print $3,$4}' | grep /var/lib/libvirt/images | while read disk file ; do
        if [ -f $file ] ; then
            virsh snapshot-create-as --domain $domain backup.$date --diskspec $disk,file=$file.$date --disk-only --atomic
            $rsync_cmd $rsyncargs $file /$backupdir/$(echo $file | sed -e "s,$mountpoint,$safename,g")
            if virsh blockcommit $domain $file.$date --shallow --active --pivot --verbose ; then
                rm $file.$date
                virsh snapshot-delete $domain backup.$date --metadata
            else
                echo Snapshot removal of backup.$date from $domain failed
            fi
        else
            echo File $file not found, skipping
        fi
    done
done
}


if [ x$libvirtbackup = xtrue ] ; then
    echo "Backing up libvirt disk images"
    backupdir=$backupfs
    libvirtbackup
fi

logger ZFS backup completed
zfs-control.sh stop
