#!/bin/bash

set -e

export CORE_CONF_fs_defaultFS=${CORE_CONF_fs_defaultFS:-hdfs://$(hostname)}

add_property () {
  # echo "Set $2=$3"
  local entry=$(echo "<property><name>$2</name><value>${3}</value></property>" | sed 's/\//\\\//g')
  sed -i "/<\/configuration>/ s/.*/${entry}\n&/" $1
}

configure() {
    # echo "configure $1-site.xml"
    conf=$HADOOP_CONF_DIR/$1-site.xml

    if [ ! -e "$conf" ]; then
    	echo "Configfile $conf not exists!"
    	return 1
	fi
	PREFIX=${1^^}_CONF

	for key in $(printenv | perl -sne 'print "$1 " if m/^${envPrefix}_(.+?)=.*/' -- -envPrefix=$PREFIX); do
		name=`echo ${key} | perl -pe 's/___/-/g; s/__/@/g; s/_/./g; s/@/_/g;'`
		var="${PREFIX}_$key"
		add_property $conf "$name" "${!var}"
	done
}

for module in core hdfs yarn httpfs kms mapred; do
	configure $module
done

exec $@