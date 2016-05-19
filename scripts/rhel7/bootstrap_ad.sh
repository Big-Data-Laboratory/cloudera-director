#!/bin/bash

#### Configurations ####

# DNS server, probably AD domain controller
NAMESERVER="XXX.XXX.XXX.XXX"

# Centrify adjoin parameters
PREWIN2K_HOSTNAME=$(hostname -f | sed -e 's/^ip-//' | sed -e 's/\.ec2\.internal//')
DOMAIN="CLOUDERA.LOCAL"
COMPUTER_OU="ou=servers,ou=prod,ou=clusters,ou=cloudera"
ADJOIN_USER="centrify"
ADJOIN_PASSWORD="Cloudera!"

# Centrify adcert parameters
WINDOWS_CA="example-SERVER1-CA"
WINDOWS_CA_SERVER="server1.example.com"
CERT_TEMPLATE="Centrify"

# Cloudera base directory
CLOUDERA_BASE_DIR="/opt/cloudera/security"

# Centrify base cert directory - shouldn't need to be changed
CENTRIFY_BASE_DIR="/var/centrify/net/certs"

# Passwords for certificate objects
PRIVATE_KEY_PASSWORD="Cloudera!"
KEYSTORE_PASSWORD="Cloudera!"
TRUSTSTORE_PASSWORD="Cloudera!"

#### SCRIPT START ####

# Set SELinux to permissive
setenforce 0

# Update DNS settings to point to the AD domain controller
sed -e 's/PEERDNS\=\"yes\"/PEERDNS\=\"no\"/' -i /etc/sysconfig/network-scripts/ifcfg-eth0
chattr -i /etc/resolv.conf
sed -e "s/nameserver .*/nameserver $NAMESERVER/" -i /etc/resolv.conf
chattr +i /etc/resolv.conf

# Install base packages
yum install -y perl wget unzip krb5-workstation openldap-clients rng-tools

# Enable and start rngd
systemctl enable rngd
systemctl start rngd

# Update packages and remove OpenJDK
yum erase -y java-1.6.0-openjdk java-1.7.0-openjdk
wget --no-cookies --no-check-certificate --header "Cookie: oraclelicense=accept-securebackup-cookie" "http://download.oracle.com/otn-pub/java/jdk/8u60-b27/jdk-8u60-linux-x64.rpm" -O jdk-8-linux-x64.rpm
rpm -i jdk-8-linux-x64.rpm
export JAVA_HOME=/usr/java/jdk1.8.0_60
export PATH=$JAVA_HOME/bin:$PATH
rm -f jdk-8-linux-x64.rpm
 
# Download the JCE and install it
wget --no-check-certificate --no-cookies --header "Cookie: oraclelicense=accept-securebackup-cookie" "http://download.oracle.com/otn-pub/java/jce/8/jce_policy-8.zip" -O UnlimitedJCEPolicyJDK8.zip
unzip UnlimitedJCEPolicyJDK8.zip
cp -f UnlimitedJCEPolicyJDK8/*.jar /usr/java/jdk1.8.0_60/jre/lib/security/
rm -rf UnlimitedJCEPolicyJDK8*

# Download and install the Centrify bits
wget http://edge.centrify.com/products/centrify-suite/2016/installers/20160315/centrify-suite-2016-rhel4-x86_64.tgz
tar xzf centrify-suite-2016-rhel4-x86_64.tgz
rpm -i ./*.rpm

# If the Centrify packages didn't install, abort
if ! rpm -qa | grep -i centrify; then
    echo "Centrify packages did not install!" >&2
    exit 1;
fi

# Configure Centrify so it doesn't create the http principal when it joins the domain
sed -e 's/.*adclient\.krb5\.service\.principals.*/adclient\.krb5\.service\.principals\: ftp cifs nfs/' -i /etc/centrifydc/centrifydc.conf

# Configure Centrify to turn off automatic clock syncing to AD since the hosts use ntpd already
sed -e 's/.*adclient\.sntp\.enabled.*/adclient\.sntp\.enabled\: false/' -i /etc/centrifydc/centrifydc.conf

# Join the AD domain
adjoin -u "${ADJOIN_USER}" -p "${ADJOIN_PASSWORD}" -c "${COMPUTER_OU}" -w "${DOMAIN}" --prewin2k "${PREWIN2K_HOSTNAME}"

# Check if the domain join was successful
if ! adinfo | grep -qi "joined as"; then
    echo "Unable to detect a successful adjoin!" >&2
    exit 1;
fi

# Check if the Centrify certificates directory exists, because if it doesn't, something went wrong; abort
if [ ! -d ${CENTRIFY_BASE_DIR} ]; then
    mkdir -p "${CENTRIFY_BASE_DIR}"
    chmod -R 700 "${CENTRIFY_BASE_DIR}"
fi

# Create the server certificates
/usr/share/centrifydc/sbin/adcert -e -n "${WINDOWS_CA}" -s "${WINDOWS_CA_SERVER}" -t "${CERT_TEMPLATE}"

# Check if the certificates were successfully created
if [[ ! -f ${CENTRIFY_BASE_DIR}/cert.chain || ! -f ${CENTRIFY_BASE_DIR}/cert.key || ! -f ${CENTRIFY_BASE_DIR}/cert.cert ]]; then
    echo "Certificates were not created successfully!" >&2
    exit 1;
fi

# Create the directory that will contain the certificate objects
mkdir -p "${CLOUDERA_BASE_DIR}"
mkdir "${CLOUDERA_BASE_DIR}/x509"
mkdir "${CLOUDERA_BASE_DIR}/jks"
chmod -R 755 "${CLOUDERA_BASE_DIR}"

# Obtain the full hostname
HOST_NAME=$(hostname -f)

# Create the trust stores in PEM and JKS format
openssl pkcs7 -print_certs -in "${CENTRIFY_BASE_DIR}/cert.chain" -out "${CLOUDERA_BASE_DIR}/x509/truststore.pem"
chmod 644 "${CLOUDERA_BASE_DIR}/x509/truststore.pem"
keytool -importcert -trustcacerts -alias root-ca -file "${CLOUDERA_BASE_DIR}/x509/truststore.pem" -keystore "${CLOUDERA_BASE_DIR}/jks/truststore.jks" -storepass "$TRUSTSTORE_PASSWORD" -noprompt
chmod 644 "${CLOUDERA_BASE_DIR}/jks/truststore.jks"

# Create the key stores in PEM and JKS format
openssl rsa -in "${CENTRIFY_BASE_DIR}/cert.key" -out "${CLOUDERA_BASE_DIR}/x509/${HOST_NAME}.key" -aes128 -passout pass:${PRIVATE_KEY_PASSWORD}
chmod 644 "${CLOUDERA_BASE_DIR}/x509/${HOST_NAME}.key"
cp "${CENTRIFY_BASE_DIR}/cert.cert" "${CLOUDERA_BASE_DIR}/x509/${HOST_NAME}.pem"
chmod 644 "${CLOUDERA_BASE_DIR}/x509/${HOST_NAME}.pem"
chmod 644 "${CLOUDERA_BASE_DIR}/x509/${HOST_NAME}.key"
openssl pkcs12 -export -in "${CLOUDERA_BASE_DIR}/x509/${HOST_NAME}.pem" -inkey "${CENTRIFY_BASE_DIR}/cert.key" -out "${CLOUDERA_BASE_DIR}/x509/${HOST_NAME}.pfx" -passout pass:${KEYSTORE_PASSWORD}
keytool -importkeystore -srcstoretype PKCS12 -srckeystore "${CLOUDERA_BASE_DIR}/x509/${HOST_NAME}.pfx" -srcstorepass "${KEYSTORE_PASSWORD}" -destkeystore "${CLOUDERA_BASE_DIR}/jks/${HOST_NAME}.jks" -deststorepass ${KEYSTORE_PASSWORD}
chmod 644 "${CLOUDERA_BASE_DIR}/jks/${HOST_NAME}.jks"
echo ${KEYSTORE_PASSWORD} > "${CLOUDERA_BASE_DIR}/passphrase.txt"
chmod 400 "${CLOUDERA_BASE_DIR}/passphrase.txt"

# Setup JSSE cacerts
cp "${JAVA_HOME}/jre/lib/security/cacerts" "${JAVA_HOME}/jre/lib/security/jssecacerts"
chmod 644 "${JAVA_HOME}/jre/lib/security/jssecacerts"
keytool -importcert -trustcacerts -alias root-ca -file "${CLOUDERA_BASE_DIR}/x509/truststore.pem" -keystore "${JAVA_HOME}/jre/lib/security/jssecacerts" -storepass changeit -noprompt

# Setup symlinks
ln -s "${CLOUDERA_BASE_DIR}/x509/${HOST_NAME}.key" "${CLOUDERA_BASE_DIR}/x509/server.key"
ln -s "${CLOUDERA_BASE_DIR}/x509/${HOST_NAME}.pem" "${CLOUDERA_BASE_DIR}/x509/server.pem"
ln -s "${CLOUDERA_BASE_DIR}/jks/${HOST_NAME}.jks" "${CLOUDERA_BASE_DIR}/jks/server.jks"

exit 0
