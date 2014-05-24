#!/bin/sh

rm -f /tmp/ddd.cmd
echo "set remotelogfile /var/tmp/gdb.log" >> /tmp/ddd.cmd
if [ $# = 1 ]; then
	# Code is already loaded and running; connect and interrupt it now:
	echo "set remote interrupt-on-connect yes" >> /tmp/ddd.cmd
	echo "target remote localhost:$1" >> /tmp/ddd.cmd
	echo "set radix 16" >> /tmp/ddd.cmd
	ddd -geometry 827x660+600+830 --debugger /usr/local/bin/m68k-elf-gdb -x /tmp/ddd.cmd &
elif [ $# = 2 ]; then
	# Code has not been loaded; have GDB load it for us:
	echo "set remote interrupt-on-connect yes" >> /tmp/ddd.cmd
	echo "target remote localhost:$1" >> /tmp/ddd.cmd
	echo "load" >> /tmp/ddd.cmd
	echo "tbreak main" >> /tmp/ddd.cmd
	echo "set radix 16" >> /tmp/ddd.cmd
	echo "cont" >> /tmp/ddd.cmd
	/usr/local/bin/ddd -geometry 827x660+600+830 --debugger /usr/local/bin/m68k-elf-gdb -x /tmp/ddd.cmd $2
	#echo "RUN WITH: run -geometry 827x660+600+830 --debugger /usr/local/bin/m68k-elf-gdb -x /tmp/ddd.cmd $2"
	#gdb /usr/local/bin/ddd
else
	echo "Synopsis: ddd.sh <port> [<elfFile>]"
fi
