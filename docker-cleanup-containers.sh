
#! /bin/bash


HOURS_TO_KEEP=${HOURS_TO_KEEP:-4}


docker inspect $(docker ps -aq) > docker_data

sed -i 's/\(T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\)\.[0-9]*Z/\1Z/g' docker_data 

date_compare=$(echo $(( `date +%s`-$HOURS_TO_KEEP*60*60 )) | jq 'todate')


names=$(cat docker_data | jq ".[] | select (.Created < $date_compare ) | select  (.Config.Labels | ( has (\"io.rancher.container.system\") or has (\"io.rancher.container.name\") ) | not ) | .Name + \" \" + .Created ")

if [ -n "$names" ]; then
  echo "Found containers to stop and remove:"
  echo -e $names
  ids=$(cat docker_data | jq -r ".[] | select (.Created < $date_compare ) | select (.Config.Labels|length == 0) | .Id ")
  for i in $ids; do
      echo "Stopping $i"
	  docker stop $i
	  echo "Removing $i"
	  docker rm -v $i || echo "OK"
  done
fi
	  
