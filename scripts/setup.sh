#!/usr/bin/env bash

set -e

rootdir=$(readlink -f $(dirname $0))/..

function linux_iter_pci {
	# Argument is the class code
	# TODO: More specifically match against only class codes in the grep
	# step.
	lspci -mm -n | grep $1 | tr -d '"' | awk -F " " '{print "0000:"$1}'
}

function linux_bind_driver() {
	bdf="$1"
	driver_name="$2"
	old_driver_name="no driver"
	ven_dev_id=$(lspci -n -s $bdf | cut -d' ' -f3 | sed 's/:/ /')

	if [ -e "/sys/bus/pci/devices/$bdf/driver" ]; then
		old_driver_name=$(basename $(readlink /sys/bus/pci/devices/$bdf/driver))

		if [ "$driver_name" = "$old_driver_name" ]; then
			return 0
		fi

		echo "$ven_dev_id" > "/sys/bus/pci/devices/$bdf/driver/remove_id" 2> /dev/null || true
		echo "$bdf" > "/sys/bus/pci/devices/$bdf/driver/unbind"
	fi

	echo "$bdf ($ven_dev_id): $old_driver_name -> $driver_name"

	echo "$ven_dev_id" > "/sys/bus/pci/drivers/$driver_name/new_id" 2> /dev/null || true
	echo "$bdf" > "/sys/bus/pci/drivers/$driver_name/bind" 2> /dev/null || true
}

function configure_linux {
	driver_name=vfio-pci
	if [ -z "$(ls /sys/kernel/iommu_groups)" ]; then
		# No IOMMU. Use uio.
		driver_name=uio_pci_generic
	fi

	# NVMe
	modprobe $driver_name || true
	for bdf in $(linux_iter_pci 0108); do
		linux_bind_driver "$bdf" "$driver_name"
	done


	# IOAT
	TMP=`mktemp`
	#collect all the device_id info of ioat devices.
	grep "PCI_DEVICE_ID_INTEL_IOAT" $rootdir/lib/ioat/ioat_pci.h \
	| awk -F"x" '{print $2}' > $TMP

	for dev_id in `cat $TMP`; do
		# Abuse linux_iter_pci by giving it a device ID instead of a class code
		for bdf in $(linux_iter_pci $dev_id); do
			linux_bind_driver "$bdf" "$driver_name"
		done
	done
	rm $TMP

	echo "1" > "/sys/bus/pci/rescan"
}

function reset_linux {
	# NVMe
	modprobe nvme || true
	for bdf in $(linux_iter_pci 0108); do
		linux_bind_driver "$bdf" nvme
	done


	# IOAT
	TMP=`mktemp`
	#collect all the device_id info of ioat devices.
	grep "PCI_DEVICE_ID_INTEL_IOAT" $rootdir/lib/ioat/ioat_pci.h \
	| awk -F"x" '{print $2}' > $TMP

	modprobe ioatdma || true
	for dev_id in `cat $TMP`; do
		# Abuse linux_iter_pci by giving it a device ID instead of a class code
		for bdf in $(linux_iter_pci $dev_id); do
			linux_bind_driver "$bdf" ioatdma
		done
	done
	rm $TMP

	echo "1" > "/sys/bus/pci/rescan"
}

function configure_freebsd {
	TMP=`mktemp`
	AWK_PROG="{if (count > 0) printf \",\"; printf \"%s:%s:%s\",\$2,\$3,\$4; count++}"
	echo $AWK_PROG > $TMP
	PCICONF=`pciconf -l | grep 'class=0x010802\|^ioat'`
	BDFS=`echo $PCICONF | awk -F: -f $TMP`
	kldunload nic_uio.ko || true
	kenv hw.nic_uio.bdfs=$BDFS
	kldload nic_uio.ko
	rm $TMP
}

function reset_freebsd {
	kldunload contigmem.ko || true
	kldunload nic_uio.ko || true
}

mode=$1
if [ "$mode" == "" ]; then
	mode="config"
fi

if [ `uname` = Linux ]; then
	if [ "$mode" == "config" ]; then
		configure_linux
	elif [ "$mode" == "reset" ]; then
		reset_linux
	fi
else
	if [ "$mode" == "config" ]; then
		configure_freebsd
	elif [ "$mode" == "reset" ]; then
		reset_freebsd
	fi
fi

