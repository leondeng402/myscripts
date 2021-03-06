#!/bin/bash
#$ -cwd -l mem=8G,time=6:: -N AnnVCF


#This script takes a bam file or a list of bam files (filename must end ".list") and runs variant calling using the HaplotypeCaller in gVCF mode
#    InpFil - (required) - Path to Bam file to be aligned. Alternatively a file with a list of bams can be provided and the script run as an array job. List file name must end ".list"
#    RefFil - (required) - shell file containing variables with locations of reference files, jar files, and resource directories; see list below for required variables
#    LogFil - (optional) - File for logging progress
#    Flag - C - FullCadd - Annotate with full CADD database. The default is to use the caddgt10 database, which contains only variants with CADD scores that are within top 10% percentile. Using the full CADD database significantly increases the amount of time required for annotation, especially for larger vcfs (can mean the difference between 30 mins and several hours)
#    Flag - P - PipeLine - call the next step in the pipeline at the end of the job
#    Flag - B - BadET - prevent GATK from phoning home
#    Help - H - (flag) - get usage information

#list of required vairables in reference file:
# $EXOMPPLN - directory containing exome analysis pipeline scripts
# $ANNHDB - directory containing databases for annovar

#list of required tools:
# annovar <http://www.openbioinformatics.org/annovar/> <http://www.openbioinformatics.org/annovar/annovar_download_form.php>
# N.B. : The perl script "table_annovar_cadd.pl", which is used below, is a modified version of the table_annovar.pl script that was released independent of the main bundle on 24th February 2014 (see annovar homepage).  The "_cadd" version has added lines to allow for the inclusion of the phred-scaled cadd score from the cadd or caddgt10 annovar databases. In the normal perl script only the raw cadd scores are added to the annotation.

## This file also requires exome.lib.sh - which contains various functions used throughout the Exome analysis scripts; this file should be in the same directory as this script

###############################################################

#set default arguments
usage="
ExmVC.5.AnnotatewithANNOVAR.sh -i <InputFile> -r <reference_file> -l <logfile> -PH

     -i (required) - Path to VCF file or \".list\" file containing a multiple paths
     -r (required) - shell file containing variables with locations of reference files and resource directories
     -l (optional) - Log file
     -C (flag) - Annotate with full CADD database
     -P (flag) - Call next step of exome analysis pipeline after completion of script
     -X (flag) - Do not run Variant Quality Score Recalibration
     -B (flag) - Prevent GATK from phoning home - only if calling pipeline
     -H (flag) - echo this message and exit
"

PipeLine="false"
FullCadd="false"
NoRecal="false"

while getopts i:r:l:CXFPBH opt; do
    case "$opt" in
        i) InpFil="$OPTARG";;
        r) RefFil="$OPTARG";; 
        l) LogFil="$OPTARG";;
        C) FullCadd="true";;
        P) PipeLine="true";;
        X) NoRecal="true";;
        B) BadET="true";;
        H) echo "$usage"; exit;;
  esac
done

#check all required paramaters present
if [[ ! -e "$InpFil" ]] || [[ ! -e "$RefFil" ]]; then echo "Missing/Incorrect required arguments"; echo "$usage"; exit; fi

#Call the RefFil to load variables
RefFil=`readlink -f $RefFil`
source $RefFil

#Load script library
source $EXOMPPLN/exome.lib.sh #library functions begin "func" #library functions begin "func"

#Set local Variables
##Set local parameters
ArrNum=$SGE_TASK_ID
funcFilfromList #if the input is a list get the appropriate input file for this job of the array --> $InpFil
VcfFil=$InpFil #input vcf file
VcfNam=`basename $VcfFil | sed s/.gz$// | sed s/.vcf$// | sed s/.rawvariants$//` #basename for outputs
if [[ -z $LogFil ]]; then LogFil=$VcfNam.AnnVCF.log; fi # a name for the log file
TmpLog=$VcfNam.AnnVCF.temp.log #temporary log file
TmpVar=$VcfNam.tempvar
AnnFil=$VcfNam.annovar
AnnModRscript=$VcfNam.ModifyAnnovarTable.rscript.r
SnpEffFil=$VcfNam.SnpEff.vcf #SnEff annotations files
VcfFilAnn=$VcfNam.Ann.vcf # annovar annotated VCF output file
VcfFilSnF=$VcfNam.SnF.vcf # SnpEff annotated VCF output file
VcfFilOut=$VcfNam.annotated.vcf # final annotated output file

TmpDir=$VcfNam.AnnVCF.tempdir; mkdir -p $TmpDir #temporary directory
GatkLog=$VcfNam.gatklog #a log for GATK to output to, this is then trimmed and added to the script log
infofields="-A AlleleBalance -A BaseQualityRankSumTest -A Coverage -A HaplotypeScore -A HomopolymerRun -A MappingQualityRankSumTest -A MappingQualityZero -A QualByDepth -A RMSMappingQuality -A SpanningDeletions -A FisherStrand -A InbreedingCoeff" #Annotation fields for GATK to output into vcf files

#check the vcf file to see if it is zipped 
FilTyp=${VcfFil##*.}

#Start Log File
ProcessName="Annotate VCF" # Description of the script - used in log
funcWriteStartLog

##Convert VCF to ANNOVAR input file using ANNOVAR - use a trimmed vcf to all possible alternate alleles using the withfreq flag (using all samples slows this down considerably as annovar calculated the allele frequencies)
StepName="Convert VCF to ANNOVAR input file using ANNOVAR"
OneSam=`less $VcfFil | grep -m 1 ^#CHROM | cut -f 10`
StepCmd="vcftools --vcf $VcfFil --indv $OneSam --recode --out TEMP.$VcfFil;
 convert2annovar.pl -includeinfo -allsample -withfreq -format vcf4 TEMP.$VcfFil.recode.vcf -outfile $TmpVar;
 cut -f 1-5,9-13 $TmpVar > $TmpVar.2;
 mv $TmpVar.2 $TmpVar"
if [[ $FilTyp == "gz" ]]; then StepCmd=`echo $StepCmd | sed s/--vcf/--gzvcf/g`; fi
funcRunStep
rm -f TEMP.$VcfFil.recode.vcf

##Generate Annotation table
# A note regarding the annotation of multi-allelic variants: If annnovar uses "." as the NA string whilst building the annotation table (i.e. to indicate that there is no annotation for an allele), vcftools' vcf-annotate correctly ignores the annotation and adds nothing to the INFO field. For variants with multiple alternate alleles, we want to add a "." to the vcf INFO field to indicate missing data for those alternates where some alleles have annotation, i.e. e.g  "...;SIFTscr=1.234,.;..." to indicate a SIFT score for the first alternate allele and no annotation for the second. With a "." in the annovar table for the second allele we would just get "...;SIFTscr=1.234;...". Therefore we set the NA string to "%%%". The "%%%" string will be added to vcf by vcf-annotate ("...;SIFTscr=1.234,%%%;...") and then we can use sed to replace it with ".". The only problem then is that we would get "...;SIFTscr=.,.;..." for variants with no annotation at all and we don't want that, so an R script is used first to replace the "%%%" with "." in the annovar annotation table for variants where all alleles lack a particular annotation.
StepName="Build Annotation table using ANNOVAR"
################################
# change caddgt10 to cadd13gt10
# 20180906: change splicing to 5bp
################################

StepCmd="table_annovar.pl $TmpVar $ANNHDB --buildver hg19 --remove -protocol refGene,esp6500siv2_all,esp6500siv2_aa,esp6500siv2_ea,1000g2014oct_all,1000g2014oct_eur,1000g2014oct_amr,1000g2014oct_eas,1000g2014oct_afr,1000g2014oct_sas,exac03,ljb26_all,cadd13gt10,caddindel,cosmic70,genomicSuperDups -arg '-splicing 5',,,,,,,,,,,,,,, -operation g,f,f,f,f,f,f,f,f,f,f,f,f,f,f,r -otherinfo  -nastring %%%  --outfile $AnnFil"

#StepCmd="table_annovar.pl $TmpVar $ANNHDB --buildver hg19 --remove -protocol refGene,esp6500siv2_all,esp6500siv2_aa,esp6500siv2_ea,1000g2014oct_all,1000g2014oct_eur,1000g2014oct_amr,1000g2014oct_eas,1000g2014oct_afr,1000g2014oct_sas,exac03,ljb26_all,caddgt10,caddindel,cosmic70,genomicSuperDups -operation g,f,f,f,f,f,f,f,f,f,f,f,f,f,f,r -otherinfo  -nastring %%%  --outfile $AnnFil"
if [[ "$FullCadd" == "true" ]]; then 
    StepCmd=${StepCmd/caddgt10/cadd}
    echo "  Using full CADD database..." >> $TmpLog
fi
funcRunStep
AnnFil=$AnnFil.hg19_multianno.txt
rm -f $TmpVar

## Replace %%% in annotation table
StepName="Fix annotation table"
echo "options(stringsAsFactors=F)
#read in header and body seperately and fix column headers for neatness
dat <- read.table(file=\"$AnnFil\", skip=1, sep=\"\t\")
hed <- read.table(file=\"$AnnFil\", nrows=1, sep=\"\t\")
colnames(dat) <- c(hed[-length(hed)], \"CHROM\", \"POS\", \"ID\", \"REF\", \"ALT\")
# in each column replace %%% with . where there is no annotation for that locus
ind <- paste(dat[,\"CHROM\"], dat[,\"POS\"]) #locus for each line
for(i in 8:(ncol(dat)-5)) {
  has.annot <- unique(ind[grep(\"%%%\", dat[,i], invert=T)]) #loci with some annotation in the column
  no.annot <- which(!ind%in%has.annot) #all lines pertaining to loci with no annotation in the column
  if(length(no.annot)>0) { dat[no.annot,i] <- \".\" }
  if(length(has.annot)>0) { dat[ind%in%has.annot,i] <- gsub(\"^\\\\.\$\", \"%%%\", dat[ind%in%has.annot,i]) }
}
write.table(dat, \"$AnnFil\", col.names=T, row.names=F, sep=\"\t\", quote=F)
" > $AnnModRscript
StepCmd="Rscript $AnnModRscript"
funcRunStep
rm -f $AnnModRscript

##sort, replace spaces and semi-colons, zip and index
# - annovar output has spaces in the RefSeq function code, e.g. "synonymous SNV", but they are not permitted in vcf format and other tools (e.g. GATK) will throw an error if they encounter them
# - annovar separates multiple gene names in the RefSeq gene name field with semi-colons, this causes and error in the vcf
StepName="Fix annotation table - remove illegal characters"
StepCmd="head -n 1 $AnnFil > $AnnFil.tempheader; 
tail -n+2 $AnnFil | awk '{gsub( / /, \"\"); print}' | awk '{gsub( /;/, \",\"); print}' | awk '{gsub( /=/, \":\"); print}' >> $AnnFil.tempheader; 
mv $AnnFil.tempheader $AnnFil; 
bgzip $AnnFil; 
tabix -S 1 -s 59 -b 60 -e 60 $AnnFil.gz"
funcRunStep


#Incorporate annovar annotations into vcf with vcftools
StepName="Incorporate annovar annotations into vcf with vcftools"
StepCmd="less $InpFil | vcf-annotate -a $AnnFil.gz 
 -c -,-,-,-,-,-,-,-,INFO/VarClass,INFO/AAChange,INFO/ESPfreq,INFO/ESP.aa.freq,INFO/ESP.ea.freq,INFO/1KGfreq,INFO/1KG.eur.freq,INFO/1KG.amr.freq,INFO/1KG.eas.freq,INFO/1KG.afr.freq,INFO/1KG.sas.freq,INFO/ExACfreq,INFO/ExAC.afr.freq,INFO/ExAC.amr.freq,INFO/ExAC.eas.freq,INFO/ExAC.fin.freq,INFO/ExAC.nfe.freq,INFO/ExAC.oth.freq,INFO/ExAC.sas.freq,INFO/SIFTscr,INFO/SIFTprd,INFO/PP2.hdiv.scr,INFO/PP2.hdiv.prd,INFO/PP2.hvar.scr,INFO/PP2.hvar.prd,-,-,INFO/MutTscr,INFO/MutTprd,INFO/MutAscr,INFO/MutAprd,-,-,INFO/MetaSVMscr,INFO/MetaSVMprd,-,-,-,-,-,INFO/GERP,-,INFO/PhyloP,INFO/SiPhy,INFO/CADDraw,INFO/CADDphred,INFO/CADDInDelraw,INFO/CADDInDelphred,INFO/COSMIC,-,CHROM,POS,-,REF,ALT
 -d key=INFO,ID=VarClass,Number=1,Type=String,Description='Mutational Class'
 -d key=INFO,ID=AAChange,Number=1,Type=String,Description='Amino Acid change'
 -d key=INFO,ID=ESPfreq,Number=1,Type=Float,Description='Exome Sequencing Project 6500 alternative allele frequency'
 -d key=INFO,ID=ESP.aa.freq,Number=1,Type=Float,Description='Exome Sequencing Project 6500 alternative allele frequency - African Americans'
 -d key=INFO,ID=ESP.ea.freq,Number=1,Type=Float,Description='Exome Sequencing Project 6500 alternative allele frequency - European Americans'
 -d key=INFO,ID=1KGfreq,Number=1,Type=Float,Description='1000 genome alternative allele frequency - all populations'
 -d key=INFO,ID=1KG.eur.freq,Number=1,Type=Float,Description='1000 genome alternative allele frequency - European'
 -d key=INFO,ID=1KG.amr.freq,Number=1,Type=Float,Description='1000 genome alternative allele frequency - Admixed American'
 -d key=INFO,ID=1KG.eas.freq,Number=1,Type=Float,Description='1000 genome alternative allele frequency - East Asian'
 -d key=INFO,ID=1KG.afr.freq,Number=1,Type=Float,Description='1000 genome alternative allele frequency - African'
 -d key=INFO,ID=1KG.sas.freq,Number=1,Type=Float,Description='1000 genome alternative allele frequency - South Asian'
 -d key=INFO,ID=ExACfreq,Number=1,Type=Float,Description='Exome Aggregatation Consortium alternative allele frequency - all populations'
 -d key=INFO,ID=ExAC.afr.freq,Number=1,Type=Float,Description='Exome Aggregatation Consortium alternative allele frequency - African'
 -d key=INFO,ID=ExAC.amr.freq,Number=1,Type=Float,Description='Exome Aggregatation Consortium alternative allele frequency - Latino'
 -d key=INFO,ID=ExAC.eas.freq,Number=1,Type=Float,Description='Exome Aggregatation Consortium alternative allele frequency - East Asian'
 -d key=INFO,ID=ExAC.fin.freq,Number=1,Type=Float,Description='Exome Aggregatation Consortium alternative allele frequency - European (Finnish)'
 -d key=INFO,ID=ExAC.nfe.freq,Number=1,Type=Float,Description='Exome Aggregatation Consortium alternative allele frequency - European (Non-Finnish)'
 -d key=INFO,ID=ExAC.oth.freq,Number=1,Type=Float,Description='Exome Aggregatation Consortium alternative allele frequency - Other'
 -d key=INFO,ID=ExAC.sas.freq,Number=1,Type=Float,Description='Exome Aggregatation Consortium alternative allele frequency - South Asian'
 -d key=INFO,ID=SIFTscr,Number=1,Type=Float,Description='SIFT score'
 -d key=INFO,ID=SIFTprd,Number=1,Type=String,Description='SIFT prediction'
 -d key=INFO,ID=PP2.hdiv.scr,Number=1,Type=Float,Description='PolyPhen2 HDIV score'
 -d key=INFO,ID=PP2.hdiv.prd,Number=1,Type=Character,Description='PolyPhen2 HDIV prediction'
 -d key=INFO,ID=PP2.hvar.scr,Number=1,Type=Float,Description='PolyPhen2 HVAR score'
 -d key=INFO,ID=PP2.hvar.prd,Number=1,Type=Character,Description='PolyPhen2 HVAR prediction'
 -d key=INFO,ID=MutTscr,Number=1,Type=Float,Description='MutationTaster score'
 -d key=INFO,ID=MutTprd,Number=1,Type=Character,Description='MutationTaster prediction'
 -d key=INFO,ID=MutAscr,Number=1,Type=Float,Description='MutationAssessor score'
 -d key=INFO,ID=MutAprd,Number=1,Type=Character,Description='MutationAssessor prediction'
 -d key=INFO,ID=MetaSVMscr,Number=1,Type=Float,Description='MetaSVM score'
 -d key=INFO,ID=MetaSVMprd,Number=1,Type=Character,Description='MetaSVM prediction'
 -d key=INFO,ID=GERP,Number=1,Type=Float,Description='GERP++ score'
 -d key=INFO,ID=PhyloP,Number=1,Type=Float,Description='PhyloP score'
 -d key=INFO,ID=SiPhy,Number=1,Type=Float,Description='SiPhy scores'
 -d key=INFO,ID=CADDraw,Number=1,Type=Float,Description='Whole-genome raw CADD score'
 -d key=INFO,ID=CADDphred,Number=1,Type=Float,Description='Whole-genome phred-scaled CADD score'
 -d key=INFO,ID=CADDInDelraw,Number=1,Type=Float,Description='Whole-genome raw CADD InDel score'
 -d key=INFO,ID=CADDInDelphred,Number=1,Type=Float,Description='Whole-genome phred-scaled CADD InDel score'
 -d key=INFO,ID=COSMIC,Number=1,Type=String,Description='COSMIC entry ID and occurence description' > $VcfFilAnn"
funcRunStep
VcfFil=$VcfFilAnn

#for Function, gene name and Segmental duplications we only want to annotate per locus not per an allele so we make a separate table:
StepName="Make per locus annotation table"
StepCmd="gunzip -c $AnnFil | cut -f 1,2,3,4,5,6,7,58-63 | head -n 1 > $AnnFil.bylocus ; 
gunzip -c $AnnFil | cut -f 1,2,3,4,5,6,7,58-63 | tail -n +2 | awk '!a[\$9\$10]++' >> $AnnFil.bylocus ; 
bgzip $AnnFil.bylocus ;
tabix -S 1 -s 9 -b 10 -e 10 $AnnFil.bylocus.gz"
funcRunStep

#Incorporate annovar annotations into vcf with vcftools
StepName="Incorporate annovar annotations into vcf with vcftools"
StepCmd="cat $VcfFil | vcf-annotate -a $AnnFil.bylocus.gz 
 -c -,-,-,-,-,INFO/VarFunc,INFO/GeneName,INFO/SegDup,CHROM,POS,-,REF,ALT
 -d key=INFO,ID=VarFunc,Number=1,Type=String,Description='Genomic region/Sequence Function'
 -d key=INFO,ID=GeneName,Number=1,Type=String,Description='refGene GeneName'
 -d key=INFO,ID=SegDup,Number=1,Type=String,Description='Genomic Segmental duplications, Score=fracMatchIndel from UCSC, Name=matching segment ' > $VcfFilAnn.ann2;
sed -i 's/%%%/./g' $VcfFilAnn.ann2"
funcRunStep 
mv $VcfFilAnn.ann2 $VcfFil
#rm -f $AnnFil.bylocus*

#Get snpEff annotations
StepName="Get snpEff annotations"
StepCmd="java -Xmx6G -jar $SNPEFF eff -o gatk  -v GRCh37.75 $VcfFil > $SnpEffFil"
###funcRunStep

#Incorporate snpEff annotations into vcf with GATK, also ensure complete GATK annotations (dbSNP etc.)
StepName="Joint call gVCFs" >> $TmpLog
StepCmd="java -Xmx5G -Djava.io.tmpdir=$TmpDir -jar $GATKJAR
 -T VariantAnnotator 
 -R $REF
 -L $VcfFil
 -V $VcfFil
 -o $VcfFilSnF
 -D $DBSNP
  $infofields
  -A SnpEff
  --snpEffFile $SnpEffFil  \
 -log $GatkLog" #command to be run
funcGatkAddArguments # Adds additional parameters to the GATK command depending on flags (e.g. -B or -F)
###funcRunStep
##rm $VcfFilAnn
#VcfFil=$VcfFilSnF
## Note GATK throws a lot of warnings related to SnpEff annotations that it doesn't like. 
## e.g. WARN  14:55:15,040 SnpEff - Skipping malfo#rmed SnpEff effect field at 10:100184062. Error was: "SPLICE_SITE_REGION is not a recognized effect type". Field was: "SPLICE_SITE_REGION(LOW||||HPS1|processed_transcript|CODING|ENST00000478087|7)"
## They don't effect the annotations of the other variants. 

mv $VcfFil $VcfFilOut
VcfFil=$VcfFilOut

#gzip and index
StepName="Gzip the vcf and index" # Description of this step - used in log
StepCmd="bgzip $VcfFil; tabix -f -p vcf $VcfFil.gz"
funcRunStep
VcfFil=$VcfFil.gz

#Call next steps of pipeline if requested
NextJob="Recalibrate Variant Quality"
NextCmd="$EXOMPPLN/ExmVC.4.RecalibrateVariantQuality.sh -i $VcfFil -r $RefFil -l $LogFil -P"
if [[ "$BadET" == "true" ]]; then NextCmd=$NextCmd" -B"; fi 
if [[ "$NoRecal" == "true" ]]; then NextCmd=$NextCmd" -X"; fi
NextCmd=$NextCmd" >stdostde/AnnotateVCF.$VcfNam.o 2>stdostde/AnnotateVCF.$VcfNam.e"
funcPipeLine

#End Log
funcWriteEndLog

#Cleanup

rm -f $VcfNam*invalid_input $VcfNam*bylocus*
