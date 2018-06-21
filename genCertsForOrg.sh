#!/bin/bash

targetDir=$1
curDir=$PWD
orgName=$2

cd $targetDir
basedir=`readlink -f $orgName`
shift
entities=$@

if test -d $orgName
then
  rm -rf $orgName
fi
mkdir $orgName

trap cleanup EXIT
function cleanup {
  cd $curDir
}
cd $basedir

# generate some useful aliases
confFile=$basedir/caconf
cakeyFile=$basedir/cakey-$orgName.pem
cacertFile=$basedir/cacert-$orgName.pem
curveParamFile=$basedir/secp256k1.pem
serialFile=$basedir/serial
dbFile=$basedir/db

cat <<- EOF > $confFile
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = $basedir
certs             = $basedir/
crl_dir           = $basedir/
new_certs_dir     = $basedir/
database          = $dbFile
serial            = $basedir/serial
RANDFILE          = $basedir/
private_key       = $cakeyFile
certificate       = $cacertFile
crlnumber         = $basedir/number
crl               = $basedir/
crl_extensions    = crl_ext
default_crl_days  = 30
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 375
preserve          = no
policy            = policy_strict

[ policy_strict ]
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ usr_cert ]
basicConstraints = CA:FALSE
nsCertType = client, email
nsComment = "OpenSSL Generated Client Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, emailProtection, serverAuth

[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256
x509_extensions     = v3_ca

[ req_distinguished_name ]
0.organizationName              = Organization Name
organizationalUnitName          = Organizational Unit Name
commonName                      = Common Name
emailAddress                    = Email Address
EOF

# create the file with the serial numbers
echo 01 > $serialFile

# create an empty DB file
touch $dbFile

# generate ca private key
openssl ecparam -name prime256v1 -out $curveParamFile
openssl ecparam -in $curveParamFile -genkey -noout -out $cakeyFile

# generate ca cert
openssl req -config $confFile -key $cakeyFile -new -x509 -days 7300 -sha256 -extensions v3_ca -out $cacertFile -subj "/O=$orgName/OU=$orgName/CN=CA"

# handle each of the entities individually
for entity in $entities; do
  echo "Generating material for entity $entity"
  entityDir=$basedir/$entity
  mkdir $entityDir
  cd $entityDir
  
  adDir=$entityDir/admincerts
  caDir=$entityDir/cacerts
  kyDir=$entityDir/keystore
  ceDir=$entityDir/signcerts
  
  mkdir $adDir $caDir $kyDir $ceDir
  
  # copy the ca cert
  cp $cacertFile $caDir
  
  # generate the signing key for this entity
  keyFile=$kyDir/key-$entity.pem
  openssl ecparam -in $curveParamFile -genkey -noout -out $keyFile

  pkcs8key=$kyDir/pkcs8.key
  openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in $keyFile -out $pkcs8key
  
  # generate CSR for the entity
  csrFile=$entityDir/csr.pem
  openssl req -key $keyFile -new -sha256 -out $csrFile -subj "/O=$orgName/OU=$orgName/OU=$entity/CN=$entity"
  
  # issue a certificate for this entity
  certFile=$ceDir/cert-$entity.pem
  openssl ca -config $confFile -extensions usr_cert -days 7300 -md sha256 -in $csrFile -out $certFile -batch -notext
  
  # remove the csr
  rm $csrFile
  
  cd ..
done

# remove all extraneous files
find . -maxdepth 1 -type f -delete

# add admins
find . -name admincerts | while read admdir
do
    find . -name signcerts | while read dname
    do
        find $dname -type f | while read fn
        do
            echo cp $fn $admdir
            cp $fn $admdir
        done
    done
done









