#!/bin/bash
#/ Usage: snipeit.sh [-vh]
#/
#/ Install Snipe-IT open source asset management.
#/
#/ OPTIONS:
#/   -v | --verbose    Enable verbose output.
#/   -h | --help       Show this message.

######################################################
#      Snipe-It Install Script for Debian 11.x       #
######################################################

# Parse arguments
while true; do
  case "$1" in
    -h|--help)
      show_help=true
      shift
      ;;
    -v|--verbose)
      set -x
      verbose=true
      shift
      ;;
    -*)
      echo "Error: invalid argument: '$1'" 1>&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

print_usage () {
  grep '^#/' <"$0" | cut -c 4-
  exit 1
}

if [ -n "$show_help" ]; then
  print_usage
else
  for x in "$@"; do
    if [ "$x" = "--help" ] || [ "$x" = "-h" ]; then
      print_usage
    fi
  done
fi

# ensure running as root
if [ "$(id -u)" != "0" ]; then
    #Debian doesnt have sudo if root has a password.
    if ! hash sudo 2>/dev/null; then
        exec su -c "$0" "$@"
    else
        exec sudo "$0" "$@"
    fi
fi

clear

readonly APP_USER="snipeitapp"
readonly APP_NAME="snipeit"
readonly APP_PATH="/var/www/html/$APP_NAME"

progress () {
  spin[0]="-"
  spin[1]="\\"
  spin[2]="|"
  spin[3]="/"

  echo -n " "
  while kill -0 "$pid" > /dev/null 2>&1; do
    for i in "${spin[@]}"; do
      echo -ne "\\b$i"
      sleep .3
    done
  done
  echo ""
}

log () {
  if [ -n "$verbose" ]; then
    eval "$@" |& tee -a /var/log/snipeit-install.log
  else
    eval "$@" |& tee -a /var/log/snipeit-install.log >/dev/null 2>&1
  fi
}

install_packages () {
      for p in $PACKAGES; do
        if dpkg -s "$p" >/dev/null 2>&1; then
          echo "  * $p already installed"
        else
          echo "  * Installing $p"
          log "DEBIAN_FRONTEND=noninteractive apt-get install -y $p"
        fi
      done
}

create_virtualhost () {
  {
    echo "<VirtualHost *:80>"
    echo "  <Directory $APP_PATH/public>"
    echo "      Allow From All"
    echo "      AllowOverride All"
    echo "      Options -Indexes"
    echo "  </Directory>"
    echo ""
    echo "  DocumentRoot $APP_PATH/public"
    echo "  ServerName $fqdn"
    echo "</VirtualHost>"
  } >> "$apachefile"
}

create_user () {
  echo "* Creating Snipe-IT user."
  adduser --quiet --disabled-password --gecos '""' "$APP_USER"
  usermod -a -G "$apache_group" "$APP_USER"
}

run_as_app_user () {
  if ! hash sudo 2>/dev/null; then
      su -c "$@" $APP_USER
  else
      sudo -i -u $APP_USER "$@"
  fi
}

install_composer () {
  # https://getcomposer.org/doc/faqs/how-to-install-composer-programmatically.md
  EXPECTED_SIGNATURE="$(wget -q -O - https://composer.github.io/installer.sig)"
  run_as_app_user php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_SIGNATURE="$(run_as_app_user php -r "echo hash_file('SHA384', 'composer-setup.php');")"

  if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]
  then
      >&2 echo 'ERROR: Invalid composer installer signature'
      run_as_app_user rm composer-setup.php
      exit 1
  fi

  run_as_app_user php composer-setup.php
  run_as_app_user rm composer-setup.php

  mv "$(eval echo ~$APP_USER)"/composer.phar /usr/local/bin/composer
}

install_snipeit () {
  create_user

  echo "* Creating MariaDB Database/User."
  echo "* Please Input your MariaDB root password:"
  mysql -u root -p --execute="CREATE DATABASE snipeit;GRANT ALL PRIVILEGES ON snipeit.* TO snipeit@localhost IDENTIFIED BY '$mysqluserpw';"

  echo "* Cloning Snipe-IT from github to the web directory."
  log "git clone https://github.com/snipe/snipe-it $APP_PATH"

  echo "* Configuring .env file."
  cp "$APP_PATH/.env.example" "$APP_PATH/.env"

  #TODO escape SED delimiter in variables
  sed -i '1 i\#Created By Snipe-it Installer' "$APP_PATH/.env"
  sed -i "s|^\\(APP_TIMEZONE=\\).*|\\1$tzone|" "$APP_PATH/.env"
  sed -i "s|^\\(DB_HOST=\\).*|\\1localhost|" "$APP_PATH/.env"
  sed -i "s|^\\(DB_DATABASE=\\).*|\\1snipeit|" "$APP_PATH/.env"
  sed -i "s|^\\(DB_USERNAME=\\).*|\\1snipeit|" "$APP_PATH/.env"
  sed -i "s|^\\(DB_PASSWORD=\\).*|\\1$mysqluserpw|" "$APP_PATH/.env"
  sed -i "s|^\\(APP_URL=\\).*|\\1http://$fqdn|" "$APP_PATH/.env"

  echo "* Installing composer."
  install_composer

  echo "* Setting permissions."
  for chmod_dir in "$APP_PATH/storage" "$APP_PATH/public/uploads"; do
    chmod -R 775 "$chmod_dir"
  done

  chown -R "$APP_USER":"$apache_group" "$APP_PATH"

  echo "* Running composer."
  run_as_app_user /usr/local/bin/composer install --no-dev --prefer-source --working-dir "$APP_PATH"

  sudo chgrp -R "$apache_group" "$APP_PATH/vendor"

  echo "* Generating the application key."
  log "php $APP_PATH/artisan key:generate --force"

  echo "* Artisan Migrate."
  log "php $APP_PATH/artisan migrate --force"

  echo "* Creating scheduler cron."
  (crontab -l ; echo "* * * * * /usr/bin/php $APP_PATH/artisan schedule:run >> /dev/null 2>&1") | crontab -
}

set_hosts () {
  echo "* Setting up hosts file."
  echo >> /etc/hosts "127.0.0.1 $(hostname) $fqdn"
}

if [[ -f /etc/lsb-release || -f /etc/debian_version ]]; then
  distro="$(lsb_release -is)"
  version="$(lsb_release -rs)"
  codename="$(lsb_release -cs)"
elif [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  distro="$(source /etc/os-release && echo "$ID")"
  # shellcheck disable=SC1091
  version="$(source /etc/os-release && echo "$VERSION_ID")"
  #Order is important here.  If /etc/os-release and /etc/centos-release exist, we're on centos 7.
  #If only /etc/centos-release exist, we're on centos6(or earlier).  Centos-release is less parsable,
  #so lets assume that it's version 6 (Plus, who would be doing a new install of anything on centos5 at this point..)
  #/etc/os-release properly detects fedora
elif [ -f /etc/centos-release ]; then
  distro="centos"
  version="6"
else
  distro="unsupported"
fi

echo '
    __  ____             __   __  __
   /  |/  (_)___  __  __/ /  / / / /___  _________  ____
  / /|_/ / / __ \/ / / / /  / /_/ / __ `/ ___/ __ `/ __ \
 / /  / / / / / / /_/ / /  / __  / /_/ (__  ) /_/ / / / /
/_/  /_/_/_/ /_/\__,_/_/  /_/ /_/\__,_/____/\__,_/_/ /_/

'

echo ""
echo "  Welcome to Snipe-IT Inventory Installer for Debian 11.x"
echo ""
shopt -s nocasematch
case $distro in
  *debian*)
    echo "  The installer has detected $distro version $version codename $codename."
    distro=debian
    apache_group=www-data
    apachefile=/etc/apache2/sites-available/$APP_NAME.conf
    ;;
  *)
    echo "  The installer was unable to determine your OS. Exiting for safety."
    exit 1
    ;;
esac
shopt -u nocasematch

echo -n "  Q. What is the FQDN of your server? ($(hostname --fqdn)): "
read -r fqdn
if [ -z "$fqdn" ]; then
  readonly fqdn="$(hostname --fqdn)"
fi
echo "     Setting to $fqdn"
echo ""

ans=default
until [[ $ans == "yes" ]] || [[ $ans == "no" ]]; do
echo -n "  Q. Do you want to automatically create the database user password? (y/n) "
read -r setpw

case $setpw in
  [yY] | [yY][Ee][Ss] )
    mysqluserpw="$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c16; echo)"
    echo ""
    ans="yes"
    ;;
  [nN] | [n|N][O|o] )
    echo -n  "  Q. What do you want your snipeit user password to be?"
    read -rs mysqluserpw
    echo ""
    ans="no"
    ;;
  *)  echo "  Invalid answer. Please type y or n"
    ;;
esac
done

case $distro in
  debian)
  if [[ "$version" =~ ^11 ]]; then
    # Install for Debian 11.x
    tzone=$(cat /etc/timezone)

   # echo "* Adding PHP repository."
    log "apt-get install -y apt-transport-https"
   # log "wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg"
   # echo "deb https://packages.sury.org/php/ $codename main" > /etc/apt/sources.list.d/php.list

    echo -n "* Updating installed packages."
    log "apt-get update && apt-get -y upgrade" & pid=$!
    progress

    echo "* Installing Apache httpd, PHP, MariaDB and other requirements."
    PACKAGES="mariadb-server mariadb-client apache2 libapache2-mod-php php php-curl php-mysql php-gd php-ldap php-zip php-mbstring php-xml php-bcmath curl git unzip"
    install_packages

    echo "* Configuring Apache."
    create_virtualhost
    log "a2enmod rewrite"
    log "a2ensite $APP_NAME.conf"

    set_hosts

    echo "* Securing MariaDB."
    /usr/bin/mysql_secure_installation

    install_snipeit

    echo "* Restarting Apache httpd."
    log "service apache2 restart"
  else
    echo "Unsupported Debian version. Version found: $version, version required: 10.x"
    exit 1
  fi
  ;;
esac

setupmail=default
until [[ $setupmail == "yes" ]] || [[ $setupmail == "no" ]]; do
echo -n "  Q. Do you want to configure mail server settings? (y/n) "
read -r setupmail

case $setupmail in
  [yY] | [yY][Ee][Ss] )
    echo -n "  Outgoing mailserver address:"
    read -r mailhost
    sed -i "s|^\\(MAIL_HOST=\\).*|\\1$mailhost|" "$APP_PATH/.env"

    echo -n "  Server port number:"
    read -r mailport
    sed -i "s|^\\(MAIL_PORT=\\).*|\\1$mailport|" "$APP_PATH/.env"

    echo -n "  Username:"
    read -r mailusername
    sed -i "s|^\\(MAIL_USERNAME=\\).*|\\1$mailusername|" "$APP_PATH/.env"

    echo -n "  Password:"
    read -rs mailpassword
    sed -i "s|^\\(MAIL_PASSWORD=\\).*|\\1$mailpassword|" "$APP_PATH/.env"
    echo ""

    echo -n "  Encryption(null/TLS/SSL):"
    read -r mailencryption
    sed -i "s|^\\(MAIL_ENCRYPTION=\\).*|\\1$mailencryption|" "$APP_PATH/.env"

    echo -n "  From address:"
    read -r mailfromaddr
    sed -i "s|^\\(MAIL_FROM_ADDR=\\).*|\\1$mailfromaddr|" "$APP_PATH/.env"

    echo -n "  From name:"
    read -r mailfromname
    sed -i "s|^\\(MAIL_FROM_NAME=\\).*|\\1$mailfromname|" "$APP_PATH/.env"

    echo -n "  Reply to address:"
    read -r mailreplytoaddr
    sed -i "s|^\\(MAIL_REPLYTO_ADDR=\\).*|\\1$mailreplytoaddr|" "$APP_PATH/.env"

    echo -n "  Reply to name:"
    read -r mailreplytoname
    sed -i "s|^\\(MAIL_REPLYTO_NAME=\\).*|\\1$mailreplytoname|" "$APP_PATH/.env"
    setupmail="yes"
    ;;
  [nN] | [n|N][O|o] )
    setupmail="no"
    ;;
  *)  echo "  Invalid answer. Please type y or n"
    ;;
esac
done
for chmod_dir in "$APP_PATH/storage" "$APP_PATH/public/uploads"; do
  chmod -R 775 "$chmod_dir"
done
chown -R "$APP_USER":"$apache_group" "$APP_PATH"
echo ""
echo "  ***Open http://$fqdn to login to Snipe-IT.***"
echo ""
echo ""
echo "* Cleaning up..."
rm -f snipeit.sh
rm -f install.sh
echo "* Finished!"
sleep 1
