cd "$(mktemp -d)" || exit 1
printf 'aaaa' > small; head -c 3000000 /dev/zero > big; mkdir sub; ln -s small lnk; : > 'файл'
echo "1"; lsx | sort-by name | pick name type size
echo "2"; lsx | where size -gt 1mb | pick name; lsx | where 'size >= 4kib' | where 'name != big' | pick name
echo "3"; lsx | where type == dir | count
echo "4"; lsx | where name =~ '^s' | sort-by -r name | first 1 | pick name
echo "5"; printf 'name,age\n"Smith, J",42\nAnn,7\n' | from csv | sort-by age | to json
echo "6"; echo '[{"a":1,"b":"x"},{"a":2,"c":[1,2]}]' | from json | to csv
echo "7"; echo '{"k":"v","n":3}' | from json
echo "8"; printf 'PID TTY CMD\n1 ? init --x\n22 pts/0 sh\n' | from ssv | where PID gt 5 | pick CMD
echo "9"; psx | where pid == $$ | pick name
echo "10"; lsx | first 2 | count
echo "11"; lsx | reject mode modified | last 1
echo "12"; lsx | where nosuch == 1
echo "13 $?"
