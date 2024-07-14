#!/bin/bash
export UPIN=123456 # default
export APIN=12345678 # default
export GNUPGHOME=/.gpg
export RED="\033[31m"
export GREEN="\033[32m"
export YELLOW="\033[33m"
export BLUE="\033[34m"
export PURPLE="\033[35m"
export CYAN="\033[36m"
export REDBG="\033[41m"
export GREENBG="\033[42m"
export YELLOWBG="\033[43m"
export BLUEBG="\033[44m"
export PURPLEBG="\033[45m"
export CYANBG="\033[46m"
export NOCOL="\033[m"

function die(){
  echo >&2
  error "$1\n" 
  if [ -f /KEYVOL ]
  then
    info "Unmounting and closing Keystore. "
    cd /
    pkill scdaemon
    pkill gpg-agent
    pkill pcscd
    sleep 1
    umount $GNUPGHOME &>/dev/null 
    cryptsetup luksClose keyringvol &>/dev/null
    ok
    info "Backing out Keystore to shared volume. "
    mv /KEYVOL /pgp-ca/ && ok
  fi
  exit $2
}

function fail(){
  echo -e "\033[250D\033[72C${RED}[failed]$NOCOL" >&2
}

function ok(){
  echo -e "\033[250D\033[76C${GREEN}[ok]$NOCOL" >&2
}

function rcStat(){
  if [ $1 -eq 0 ]
  then
    ok
    return 0
  else
    fail
    return 1
  fi
}

function error(){
  echo -n -e "${RED}[ERROR]$NOCOL $1" >&2
}

function info(){
  echo -n -e "${BLUE}[INFO]$NOCOL $1" >&2
}

function warn(){
  echo -n -e "${YELLOW}[WARNING]$NOCOL $1" >&2
}

function initialize(){
  info "Initializing KEYVOL.\n"
  read -s -p "Passphrase for KEYVOL - leave empty to generate one: "
  echo
  PASSPHRASE=${REPLY:-$(LC_ALL=C tr -dc 'A-Z1-9' < /dev/urandom | \
	  tr -d "1IOS5U" | fold -w 30 | sed "-es/./ /"{1..26..5} | \
	  cut -c2- | tr " " ":" | head -1)}
  echo >&2
  info "  Creating luks image file: "
  dd if=/dev/zero bs=1M count=20 of=/KEYVOL &>/dev/null || die "Failed to create file: /KEYVOL." 1
  rcStat $?
  info "  Setting up LUKS: "
  echo -n "$PASSPHRASE" | cryptsetup luksFormat /KEYVOL - || { rm /KEYVOL; die "Failed to initialize LUKS." 1; } 
  rcStat $?
  info "  Opening LUKS container: "
  echo -n "$PASSPHRASE" | cryptsetup luksOpen /KEYVOL keyringvol - || die "Failed to open LUKS container." 1
  rcStat $?
  info "  Creating file system: "
  mkfs.ext4 /dev/mapper/keyringvol &>/dev/null || die "Failed to create filesystem." 1
  rcStat $?
  info "  Mounting file system: "
  mount /dev/mapper/keyringvol $GNUPGHOME || die "Failed to mount KEYVOL." 1
  rcStat $?
  info "  Preparing GPG config: "
  cp /gpg.conf $GNUPGHOME/ &>/dev/null || die "Failed to prepare GPG config." 1
  rcStat $?
  info "This is the keystore's encryption passphrase: $RED$PASSPHRASE$NOCOL\n"
  warn "Make sure to note this passphrase down and store it securely!\n"
}

function mountKeystore(){
  read -s -p "Passphrase for keystore: " PASSPHRASE
  echo
  info "Checking out and decrypting Keystore"
  cp /pgp-ca/KEYVOL /
  echo $PASSPHRASE | cryptsetup luksOpen /KEYVOL keyringvol - || { error "Failed to decrypt Keystore. Maybe bad passphrase?"; return 1; }
  rcStat $?
  info "Mounting Keystore"
  mount /dev/mapper/keyringvol $GNUPGHOME || { error "Failed to mount Keystore."; return 1; }	 
  rcStat $?
  return 0
}

function checkYK(){
  ykserial=$(ykman list 2>/dev/null | awk -F: '{gsub(" ","",$2);print $2}')
  if [ "$ykserial" = "" ]
  then
    error "No yubikey found.\n"
    return 1
  fi
  info "Found yubikey with serial: $PURPLE$ykserial$NOCOL\n"
  return 0
}

function pgpMakeCkey(){
  info "Preparing for a new certify key:\n"
  CERTIFY_PASS=$(LC_ALL=C tr -dc 'A-Z1-9' < /dev/urandom | \
	  tr -d "1IOS5U" | fold -w 30 | sed "-es/./ /"{1..26..5} | \
	  cut -c2- | tr " " "-" | head -1) 
  info "This is the certify key's passphrase: $RED$CERTIFY_PASS$NOCOL\n"
  warn "Make sure to note this passphrase down and store it securely!\n"
  info "Creating new certify key: "
  gpg --batch --passphrase "$CERTIFY_PASS" --quick-generate-key "$IDENTITY" "$KEY_TYPE" cert never >/gpg.log 2>&1
  if rcStat $?
  then 
    info "Certify key created successfully with following key ID and fingerprint:\n"
    KEYID=$(gpg -k --with-colons "$IDENTITY" 2>/dev/null | awk -F: '/^pub:/ { print $5; exit }')
    KEYFP=$(gpg -k --with-colons "$IDENTITY" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')
    echo -e "$PURPLE"
    printf "Key ID: %40s\nKey FP: %40s\n" "$KEYID" "$KEYFP"
    echo -e "$NOCOL"
    info "Backing up certify key to $PURPLE$GNUPGHOME/$KEYID-Certify.key$NOCOL: "
    gpg --output $GNUPGHOME/$KEYID-Certify.key --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --armor --export-secret-keys $KEYID
    rcStat $?
  else
    warn "No certification key created!\n"
    info "This was gpg's output:\n"
    echo -e "$RED"
    cat /gpg.log
    echo -e "$NOCOL"
  fi
}

function pgpMakeEASkeys(){
  :>/gpg.log
  KEYID=$(gpg -k --with-colons "$IDENTITY" 2>/dev/null | awk -F: '/^pub:/ { print $5; exit }')
  KEYFP=$(gpg -k --with-colons "$IDENTITY" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')
  info "Creating new subkeys for encryption, authentication and signing:\n"
  read -s -p "Please provide certify key's passphrase: " CERTIFY_PASS
  echo
  for SUBKEY in sign encrypt auth 
  do
	  info "  creating $SUBKEY key: "
	  gpg --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --quick-add-key "$KEYFP" "$KEY_TYPE" "$SUBKEY" "$EXPIRATION" &>>/gpg.log
    rcStat $?
  done
  info "This was gpg's output:\n"
  echo -e $PURPLE
  cat /gpg.log
  echo -e $NOCOL
  info "The following keys do now exist: \n"
  echo -e "$PURPLE"
  gpg -K
  echo -e "$NOCOL"
  info "Backing up subkeys to $PURPLE$GNUPGHOME/$(date +%Y-%m-%d)_$KEYID-Subkeys.key$NOCOL:"
  gpg --output $GNUPGHOME/$(date +%Y-%m-%d)_$KEYID-Subkeys.key --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --armor --export-secret-subkeys $KEYID
  rcStat $?
}

function pgpRevKey(){
  KEYID=$(gpg -k --with-colons "$IDENTITY" 2>/dev/null | awk -F: '/^pub:/ { print $5; exit }')
  warn "This will revoke all your subkeys and export revoked keys to a keyserver.\n"
  warn "THIS CANNOT BE UNDONE!\n"
  read -p "Type YES (all uppercase) to continue: "
  [ "$REPLY" != "YES" ] && return 1
  read -s -p "Please provide certify key's passphrase: " CERTIFY_PASS
  echo
  info "Starting revocation: " 
  gpg --command-fd=0 --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --edit-key $KEYID &>/dev/null <<EOF
key 1
key 2
key 3
revkey
y
0

y
save
EOF
  rcStat $?
  pgpExportKey $(date +%Y-%m-%d).pub-revoked.asc  
  info "Publishing revoked key ID $PURPLE$KEYID$NOCOL to keyserver $KEYSERVER: "
  gpg --send-keys --keyserver $KEYSERVER "$KEYID" &>/dev/null 
  if rcStat $?
  then
    info "Deleting revoked keys: "
    gpg --command-fd=0 --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --edit-key $KEYID &>/dev/null <<EOF
key 1
key 2
key 3
delkey
y
save
EOF
    rcStat $? && return
  fi
  warn "Revoked subkeys are still in keyring. You have to edit the key manually to remove them!\n"
  warn "Don't forget to persist any changes by running 'save' before leaving gpg!\n"
  read -n 1 -p "Press any key to enter gpg: "
  gpg --edit-key $KEYID
}

function pgpChgKeyExp(){
  KEYFP=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^fpr:/ { print $10; exit }')
  info "Going to extend lifetime of your EAS subkeys.\n"
  read -s -p "Please provide certify key's passphrase: " CERTIFY_PASS
  echo
  read -p "Please enter expiration in years: " EXP
  info "Starting key edit: " 
  gpg --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --quick-set-expire "$KEYFP" "$EXP" "*" &>/dev/null
  if rcStat $?
  then
    pgpExportKey $(date +%Y-%m-%d).pub.asc
  fi
}

function pgpExportKey(){
  KEYID=$(gpg -k --with-colons "$IDENTITY" 2>/dev/null | awk -F: '/^pub:/ { print $5; exit }')
  info "Exporting public key ID $PURPLE$KEYID$NOCOL: "
  gpg --export --armor "$KEYID" > /pgp-ca/${KEYID}.$1  
  if rcStat $? 
  then
    info "Public key can now be found in mounted volume ($PURPLE${KEYID}.$1$NOCOL)"
    return 0
  else
    return 1
  fi
}

function ykChangePIN(){
  checkYK || return 1
  warn "This will change DEFAULT user and admin PINs of your yubikey's openpgp interface!\n"
  warn "Type YES (all uppercase) to continue: "
  read 
  echo >&2
  if [ "$REPLY" = "YES" ]
  then
    read -s -p "New user PIN - Leave empty to generate a random one: " 
    echo
    UPIN=${REPLY:-$(LC_ALL=C tr -dc '0-9' < /dev/urandom | fold -w6 | head -1)}
    read -s -p "New admin PIN - Leave empty to generate a random one: " 
    echo
    APIN=${REPLY:-$(LC_ALL=C tr -dc '0-9' < /dev/urandom | fold -w8 | head -1)}
    info "Setting admin PIN to $RED$APIN$NOCOL: "
    ykman openpgp access change-admin-pin 2>/dev/null <<EOF 
12345678
$APIN
$APIN
EOF
    rcStat $?
    info "Setting user PIN to $RED$UPIN$NOCOL: "
    ykman openpgp access change-pin 2>/dev/null <<EOF
123456
$UPIN
$UPIN
EOF
    if rcStat $?
    then
      if [ -r $GNUPGHOME/yubikey-$ykserial.txt ]
      then
        grep -v PIN $GNUPGHOME/yubikey-$ykserial.txt > $GNUPGHOME/temp && mv $GNUPGHOME/temp $GNUPGHOME/yubikey-$ykserial.txt
          cat <<EOF >>$GNUPGHOME/yubikey-$ykserial.txt
Initial user PIN: $UPIN
Admin PIN:        $APIN
EOF
      else
         cat <<EOF >$GNUPGHOME/yubikey-$ykserial.txt
Serial#:          $ykserial
Cardholder Name:  $YKCHOLDER 
Cardholder Email: $YKLOGIN
PGP Key ID:       0x$KEYID
Initial user PIN: $UPIN
Admin PIN:        $APIN
EOF
      fi
    fi
  fi
  info "Configuring Yubikey to require touch for signing:"
  ykman openpgp keys set-touch -a $APIN -f sig Cached  &>/dev/null
  rcStat $?
  info "Configuring Yubikey to require touch for authentication:"
  ykman openpgp keys set-touch -a $APIN -f sig Cached &>/dev/null
  rcStat $?
}

function ykReset(){
  checkYK || return 1
  warn "This will reset the yubikey's openpgp application to factory default!\n"
  warn "Type YES (all uppercase) to continue: "
  read 
  echo >&2
  if [ "$REPLY" = "YES" ]
  then
    info "Resetting yubikey: " 
    echo "y" | ykman openpgp reset &>/dev/null
    if rcStat $?
    then
      info "New user PIN: ${RED}1234$NOCOL\n"
      info "New admin PIN: ${RED}12345678$NOCOL\n"
      info "Reset code: ${RED}NOT SET$NOCOL\n"
    fi
    rm $GNUPGHOME/yubikey-$ykserial.txt &>/dev/null
  fi
}

function ykProvision(){
  KEYID=$(gpg -k --with-colons "$IDENTITY" 2>/dev/null | awk -F: '/^pub:/ { print $5; exit }')
  checkYK || return 1
  info "Personalizing yubikey for identity $PURPLE$IDENTITY$NOCOL: \n"
  read -p "Cardholder's full name: " YKCHOLDER
  read -p "Cardholder's email address: " YKLOGIN
  read -s -p "Yubikey admin PIN: " APIN
  echo
 # due to a bug in GPG ("gpg: KEYTOCARD failed: Invalid time") we cannot pass the passphrase via STDIN
 # read -s -p "PGP certification passphrase: " CERTIFYPASS
 # echo

  info "Setting smartcard data: "
  gpg --batch --passphrase $APIN --command-fd=0 --pinentry-mode=loopback --edit-card 2>/dev/null <<EOF
admin
login
$YKLOGIN
forcesig
name
$YKCHOLDER

quit
EOF
  rcStat $? || die "Could not personalize yubikey."
  cat <<EOF >$GNUPGHOME/yubikey-$ykserial.txt
Serial#:          $ykserial
Cardholder Name:  $YKCHOLDER 
Cardholder Email: $YKLOGIN
PGP Key ID:       0x$KEYID
Admin PIN:        $APIN
Initial user PIN: $UPIN
EOF
  info "Writing subkeys of key ID $PURPLE$KEYID$NOCOL to yubikey. \n"
  warn "You will have to provide both, Yubikey admin PIN and ccertification passphrase, three times!\n"
  read -p "Press <enter> to proceed:"
  info "  Exporting signature key: "
  cat <<EOF > /tmp/gpg-cmd
key 1
keytocard
1
EOF
  gpg --command-file /tmp/gpg-cmd --batch --edit-key $KEYID &>/dev/null 
  rcStat $? || return 1

  info "  Exporting encryption key: "
  cat <<EOF > /tmp/gpg-cmd
key 2
keytocard
2
EOF
  gpg --command-file /tmp/gpg-cmd --batch --edit-key $KEYID &>/dev/null 
  rcStat $? || return 1

  info "  Exporting authentication key: "
   cat <<EOF > /tmp/gpg-cmd
key 3
keytocard
3
EOF
  gpg --command-file /tmp/gpg-cmd --batch --edit-key $KEYID &>/dev/null 
  rcStat $? || return 1
  return 0
}

### main ###

trap 'die "Execution aborted by user." 255' INT
info "Starting PCSCD: "
pcscd --disable-polkit
rcStat $?

case "$1" in
  "prune")
    info "Cleaning up: "
    cryptsetup luksClose keyringvol &>/dev/null
    rm /dev/mapper/keyringvol &>/dev/null
    ok
    exit 0
  ;;
  "shell")
    info "Entering shell: \n"
    /bin/bash
    exit 0
  ;;
esac

if [ -f /dev/mapper/keyringvol ]
then
  error "Another instance seems to be running."
  error "Run container with arg 'prune' to clean up."
  exit 1
fi  

if [ -r /pgp-ca/KEYVOL ]
then
  info "Starting up - preparing Keystore\n"
  mountKeystore || die "Exiting."
else
  info "Starting up - initializing Keystore\n"
  initialize
fi

while :
do
  clear
  echo -e "$PURPLE"
  cat << "EOF" >&2
++==================================================================++
||   .______.     ______ .______.            ______       .         ||
||   |_   __ \  .' ___  ||_   __ \         .' ___  |     / \        ||
||     | |__) |/ .'   \_|  | |__) |______ / .'   \_|    / _ \       ||
||     |  ___/ | |   ____  |  ___/|______|| |          / ___ \      ||
||    _| |_    \ `.___]  |_| |_           \ `.___.'\ _/ /   \ \_    ||
||   |_____|    `._____.'|_____|           `.____ .'|____| |____|   ||
||                                                                  ||
++==================================================================++
EOF
  echo -e "$CYAN"
  cat <<EOF >&2
Please choose from the following options:

  1) Create a new certification key
  2) Create and certify new EAS subkeys
  3) List keys in keyring
  4) Export public key
  5) Reset yubikey's openpgp app to factory default 
  6) Set yubikey PINs
  7) Provision keys to yubikey
  8) Export keys to keyserver
  9) Change EAS subkeys' expiration date
  R) Revoke EAS subkeys
  p) Print yubikey info
  P) Print info for all known yubikeys
  s) Open an interactive shell
  e) Clean up and exit 
EOF
  echo -e "$NOCOL"
  read -n 1 -p "Your choice: " cmd
  echo >&2
  case $cmd in
    "e")
      info "Unmounting keystore"
      pkill scdaemon
      pkill gpg-agent
      pkill pcscd
      sleep 1
      cd / && umount $GNUPGHOME && cryptsetup luksClose keyringvol
      rcStat $?
      info "Backing out keystore to shared volume: "
      mv /KEYVOL /pgp-ca/ && ok
      info "Exiting."
      exit
    ;;
    "1")
      pgpMakeCkey
    ;;
    "2")
      pgpMakeEASkeys
    ;;
    "3")
      info "The following keys are currently in your keyring: \n"
      echo -e "$PURPLE"
      gpg -K
      echo -e "$NOCOL"
    ;;
    "4")
      pgpExportKey pub.asc
    ;;
    "5")
      ykReset
    ;;
    "6")
      ykChangePIN
    ;;
    "7")
      ykProvision || error "Failed to provision Yubikey!\n"
    ;;
    "8")
      KEYID=$(gpg -k --with-colons "$IDENTITY" 2>/dev/null | awk -F: '/^pub:/ { print $5; exit }')
      info "Publishing key ID $KEYID for identity $IDENTITY to keyserver $KEYSERVER: "
      gpg --send-keys --keyserver $KEYSERVER "$KEYID" &>/dev/null
      rcStat $?
    ;;
    "9")
      pgpChgKeyExp
    ;;
    "R")
      pgpRevKey
    ;;
    "p")
      if checkYK
      then
        if [ -r $GNUPGHOME/yubikey-$ykserial.txt ]
        then
          info "This is the configuration of currently detected yubikey:\n"
          echo -e "$PURPLE"
          cat $GNUPGHOME/yubikey-$ykserial.txt
          echo -e "$NOCOL"
        else
          warn "No configuration found for key with serial $ykserial!\n"
        fi
      fi
    ;;
    "P")
      info "These are the configurations of all currently known yubikeys:\n"
      echo -e "$PURPLE"
      for f in $GNUPGHOME/yubikey-*.txt
      do
        echo "===================="
        cat $f 2>/dev/null || error "Cannot find any configurations!\n"
      done
      echo -e "$NOCOL"
    ;;
    s)
      info "Entering Shell.\n"
      /bin/bash
      info "Left shell.\n"
    ;;
    *)
      error "Command not recognized!\n"
    ;;
  esac
  echo
  echo -e "$PURPLE"
  read -n 1 -p "Press any key to continue:"
done
