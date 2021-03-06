#!/bin/bash
# ---------------------------------------------------------------------------
# 52north-sos.sh - Install and manage 52North SOS

# Copyright 2016, Natanael Simões, <natanael.simoes@ifro.edu.br>

#Permission is hereby granted, free of charge, to any person obtaining a copy
#of this software and associated documentation files (the "Software"), to deal
#in the Software without restriction, including without limitation the rights
#to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#copies of the Software, and to permit persons to whom the Software is
#furnished to do so, subject to the following conditions:
#The above copyright notice and this permission notice shall be included in all
#copies or substantial portions of the Software.
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#SOFTWARE.

# Usage: 52north-sos.sh [-h|--help] [-i|--install] [-t|--host host] [-u|--update] [-s|--self-update]
# ---------------------------------------------------------------------------

PROGNAME=${0##*/}
VERSION="1.0"
PROGPATH=$BASH_SOURCE

clean_up() { # Perform pre-exit housekeeping
  return
}

error_exit() { # Exit with error observation
  printf "${PROGNAME}: ${1:-"Unknown Error"}" >&2
  printf "\n"
  clean_up
  exit 1
}

graceful_exit() { # Exit without errors
  clean_up
  exit
}

signal_exit() { # Handle trapped signals
  case $1 in
    INT)
      error_exit "Program interrupted by user" ;;
    TERM)
      echo -e "\n$PROGNAME: Program terminated" >&2
      graceful_exit ;;
    *)
      error_exit "$PROGNAME: Terminating on unknown signal" ;;
  esac
}

usage() { # Print usage message
  printf "Usage: $PROGNAME [-h|--help] [-i|--install] [-t|--host host] [-u|--update] [-s|--self-update]"
}

help_message() { # Return help message
  cat <<- _EOF_
  $PROGNAME ver. $VERSION
  Install and manage 52North SOS

  $(usage)

  Options:
  -h, --help         Display this help message and exit.
  -i, --install      Install 52North SOS for the first time.
  -t, --host host    Set the specified argument as the host
                     (to configure jsClient API provider).
                     Will use eth0 address as default if not set.
                     Where 'host' is the IP address or network name.
  -u, --update       Update 52North SOS if a new version is available
  -s, --self-update  Self-update this script is a new version is available

  NOTE: You must be the superuser to run this script.

_EOF_
  return
}

tomcat_user_file() { # Return Tomcat user file
  cat <<- _EOF_
<?xml version='1.0' encoding='utf-8'?>
<tomcat-users>
  <role rolename="manager-gui"/>
  <role rolename="manager-script"/>
  <role rolename="admin-gui"/>
  <user username="uefs" password="uefs" roles="manager-gui,admin-gui"/>
</tomcat-users>
_EOF_
  return
}

sos_client_settings_file() {
  cat <<- _EOF_
{
  "selectedLineWidth": 4,
  "commonLineWidth": 1,
  "restApiUrls": {
    "http://$iphost:8080/52n-sos-webapp/api/v1/": "localhost"
  },
  "defaultProvider": {
    "serviceID": "1",
    "apiUrl": "http://$iphost:8080/52n-sos-webapp/api/v1/"
  },
  "chartOptions":{
    "yaxis":{
      "tickDecimals" : 2
    }
  }
}
_EOF_
  return
}

# Trap signals
trap "signal_exit TERM" TERM HUP
trap "signal_exit INT"  INT

check_root() { # Check for root UID
  if [[ $(id -u) != 0 ]]; then
    error_exit "You must be the superuser to run this script."
  fi
}

add_repositories() { # Add needed repositores
  REPOADDED=$(grep 'apt.postgresql' /etc/apt/sources.list)
  if [[ $REPOADDED == "" ]]; then
    printf "Adding needed repositories..."
    OSCODENAME=$(cat /etc/*-release | grep "DISTRIB_CODENAME=") #Get distribution codename
    OSCODENAME=$(echo $OSCODENAME| cut -d '=' -f 2)
    apt-get -qq -y install python-software-properties
    add-apt-repository ppa:webupd8team/java -y
    if [[ $OSCODENAME != 'vivid' ]]; then
      echo "deb http://apt.postgresql.org/pub/repos/apt $OSCODENAME-pgdg main" >> /etc/apt/sources.list
    fi
    wget --quiet -O - http://apt.postgresql.org/pub/repos/apt/ACCC4CF8.asc | sudo apt-key add -
    clear
    printf "Updating repositories...\n"
    apt-get update
  fi
  clear
}

install_requisites() {
  printf "Installing Git...\n";
  apt-get -qq -y install git
  printf "\nInstalling XMLStarlet...\n";
  apt-get -qq -y install xml-twig-tools
  printf "\nInstalling Maven...\n";
  apt-get -qq -y install maven
  if [[ $JAVA_HOME == "" ]]; then
    printf "\nInstalling Java 7...\n";
    apt-get -qq -y install oracle-java7-installer
    apt-get -qq -y install oracle-java7-set-default
    source /etc/profile
  fi
  printf "\nInstalling Tomcat 7...\n";
  apt-get -qq -y install tomcat7 tomcat7-admin ant
  TUSERS=$(tomcat_user_file)
  printf "$TUSERS" > /etc/tomcat7/tomcat-users.xml
  printf "\nInstalling PostgreSQL 9.4 + PostGIS...\n";
  apt-get -qq -m -y install postgresql-9.4-postgis-2.1 postgresql-contrib-9.4
  service tomcat7 restart
}

configure_database() {
  DBEXISTS=$(sudo -u postgres psql -c "\l" | grep sos2)
  if [[ $DBEXISTS == '' ]]; then
    sudo -u postgres createdb sos2
    sudo -u postgres psql sos2 -c "CREATE EXTENSION postgis;"
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'postgres';"
  fi
}

build_sos() {
  PGTEMPLATE="/root/SOS/misc/conf/datasource.properties.postgres.template.seriesConcept"
  DATASOURCE="/root/SOS/misc/conf/datasource.properties"
  if [ -f /root/SOS/pom.xml ]; then
    cd /root/SOS/
    CURVERSION=$(xml_grep 'project/version' /root/SOS/pom.xml --text_only)
    CURCOMMITID=$(git log -n 1 --pretty=format:"%H")
  fi
  wget --quiet https://raw.githubusercontent.com/natanaelsimoes/52north-sos-sh/master/VERSION
  REMOTECOMMITID=$(cat VERSION)
  rm VERSION
  if [[ $CURCOMMITID != $REMOTECOMMITID ]]; then
    printf "\nCloning/updating 52North SOS source code (it will take a while)\n"
    if [ ! -d /root/SOS/ ]; then
      git clone https://github.com/52north/SOS /root/SOS
      cd /root/SOS/
    else
      cd /root/SOS/
      git pull
    fi
    git reset --hard $REMOTECOMMITID
    NEWVERSION=$(xml_grep 'project/version' /root/SOS/pom.xml --text_only)
    rm $DATASOURCE > /dev/null
    cp $PGTEMPLATE $DATASOURCE
    clear
    sleep 2 | printf "\nPreparing to compile 52North SOS, plese take a break (it will take around 30 minutes)...\n"
    sleep 1 | printf "Starts in 3... "
    sleep 1 | printf "2..."
    sleep 1 | printf "1...\n\n"
    set_host
    mvn package -Pconfigure-datasource,use-default-settings
    if [[ $CURVERSION != "" ]]; then
      wget --http-user=uefs --http-password=uefs "http://localhost:8080/manager/text/undeploy?path=/52n-sos-webapp&version=$CURVERSION" --quiet -O -
    fi
    cp /root/SOS/webapp-bundle/target/52n-sos-webapp\#\#$NEWVERSION.war /var/lib/tomcat7/webapps/
  else
    update_host $CURVERSION
    printf "\n52North SOS is up-to-date (v. $CURVERSION)\n"
  fi
}

set_host() {
  JSSETINGS=$(sos_client_settings_file)
  printf "$JSSETINGS" > /root/SOS/webapp-bundle/src/main/webapp/static/client/jsClient/settings.json
}

update_host() {
  JSSETINGS=$(sos_client_settings_file)
  printf "$JSSETINGS" > /var/lib/tomcat7/webapps/52n-sos-webapp\#\#$1/static/client/jsClient/settings.json
}

check_host_ip() {
  if [[ $iphost == "" ]]; then
    iphost=$(ifconfig eth0 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}')
    if [[ $iphost == "" ]]; then
      error_exit "Could not get this host IP automatically, please provide one with --host parameter"
    fi
  fi
}

install_sos() {
  check_root
  check_host_ip
  add_repositories
  install_requisites
  configure_database
  build_sos
  printf "\n\nInstalation completed. Visit http://$iphost:8080/52n-sos-webapp/ to start using 52North SOS.\n\n"
}

update_sos() {
  check_root
  check_host_ip
  build_sos
  printf "\n\nUpdate completed. Visit http://$iphost:8080/52n-sos-webapp/ to start using 52North SOS.\n\n"
}

self_update() {
  check_root
  printf "Downloading latest version...\n"
  if ! wget --quiet --output-document="$PROGNAME.tmp" https://raw.githubusercontent.com/natanaelsimoes/52north-sos-sh/master/52north-sos.sh ; then
    error_exit "Some error occurred while trying to get new version."
  fi  
  CHMOD=$(stat -c '%a' $PROGPATH)
  CHOWN=$(stat -c '%U:%G' $PROGPATH)
  if ! chmod $CHMOD "$PROGNAME.tmp" ; then
    error_exit "Some error occurred while trying to set chmod"
  fi
  if ! chown $CHOWN "$PROGNAME.tmp" ; then
    error_exit "Some error occurred while trying to set chown"
  fi
  cat > update_sos.sh << _EOF_
#!/bin/bash
if mv "$PROGNAME.tmp" "$PROGPATH"; then
  printf "\nSelf-update completed.\n"
  rm \$0
else
  printf "\nSelf-update failed.\n"
fi
_EOF_
  exec /bin/bash update_sos.sh
}

# Parse command-line
while [[ -n $1 ]]; do
  case $1 in
    -h | --help)
      help_message; graceful_exit ;;
    -i | --install)
      install=yes ;;
    -t | --host)
      shift; iphost="$1" ;;
    -u | --update)
      update=yes ;;
    -s | --self-update)
      self_update=yes ;;
    -* | --*)
      usage
      error_exit "Unknown option $1" ;;
    *)
      printf "Argument $1 to process..." ;;
  esac
  shift
done

# Main logic
if [[ $install ]]; then
  install_sos
elif [[ $update ]]; then
  update_sos
elif [[ $self_update ]]; then
  self_update
fi

graceful_exit