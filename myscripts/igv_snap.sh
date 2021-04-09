#!/bin/bash 
#testing file for github
### input information
#INDELS="/Volumes/TwoT/Desktop/breastcancer/IGV/IGV_2.3.57/variants_IGVsone.txt" ## variant sites for IGVs, Chromosome Position bamfile in each line and tab seperated.
INDELS="/home/local/users/ld402/test/igv_test/igv_test.txt" ## variant sites for IGVs, Chromosome Position bamfile in each line and tab seperated.
#BAM="/Volumes/TwoT/Desktop/breastcancer/IGV/IGV_2.3.57/bams_12_4.txt" ## bam file locations
BAM="/home/local/users/ld402/test/igv_test/bam_location.txt" ## bam file locations
#BAM="/home/local/ARCS/yshen/data/RGN/Freeze5/BAM" ## bam file locations
#DIR="/Volumes/TwoT/Desktop/breastcancer/IGV/IGV_2.3.57/" ## output folder
DIR="/home/local/users/ld402/test/igv_test/results" ## output folder
#IGVR="/Volumes/TwoT/Desktop/breastcancer/IGV/IGV_2.3.57/igv.sh" ## installed igv
IGVR="/home/local/users/ld402/biobin/IGV_2.3.68/igv.sh" ## installed igv
LEN=20 ## half length showed in IGV Panel 

###=========================================================
SCRF="igv_batch_script_v4.txt" ## tmp igv command lines

touch $SCRF
printf "#! /bin/bash\n" >> $SCRF

kk=1
BAMS0="OO"
while read line
do
	## Step 1: write the tmp IGV igv_batch_script.txt
	
	##printf "$line"
	NAME=`echo $line | cut -d ' ' -f 1`
	VALUE=`echo $line | cut -d ' ' -f 2`
	SAMPLE=`echo $line | cut -d  ' ' -f 3`
	SAMS=`echo $SAMPLE|tr "," "\n"`
	echo "line=$line"
	echo "SAMS=$SAMS"
	
	i=1
	for ONE in $SAMS;
 	do	
 		ONEBAM=`grep $ONE $BAM`
 		ONEBAM=`echo ${ONEBAM//[[:space:]]/,}`
 		echo $ONEBAM
		if [[ "$ONEBAM" != "" ]]
		then
			if [[ $i -gt 1 ]]; then
				BAMS=`echo $BAMS,$ONEBAM`
			else
				BAMS=`echo $ONEBAM`
			fi
		fi
		let i+=1	
	done
	echo "BAMS=$BAMS"
	
	let "START=$VALUE - $LEN"
	let "END=$VALUE + $LEN"
	outputf=`echo  $DIR$NAME.$START.$END.$SAMPLE.png`
	#echo $outputf
	if [[ ! -f $outputf ]];then
		if [[ ($kk -gt 1  &&  "$BAMS0" != "$BAMS" ) ||  $kk -eq 1 ]];then
			printf "new\n" >> $SCRF
			printf "genome hg19\n"  >> $SCRF
			printf "load  $BAMS\n" >> $SCRF
			printf "snapshotDirectory $DIR \n" >>  $SCRF	
		fi
	
		printf "goto chr$NAME:$START-$END \n" >> $SCRF
		printf "sort position \n" >> $SCRF
		printf "expand \n" >> $SCRF	
		#printf "collapse \n" >> $SCRF
		#printf "squish \n" >> $SCRF
		#printf "viewaspairs \n" >> $SCRF
		printf "maxPanelHeight 2000 \n" >> $SCRF
		printf "snapshot $NAME.$START.$END.$SAMPLE.png \n" >> $SCRF
		printf "\n" >> $SCRF
		
		let kk+=1
		BAMS0=$BAMS
	fi
done < "$INDELS"
printf "exit \n" >> $SCRF

## run IGV
NUMLINES=$(wc -l < "$SCRF")
if [[ $NUMLINES -gt 10 ]];then
	$IGVR  -g hg19 -b $SCRF	
	rm $SCRF
fi
	
