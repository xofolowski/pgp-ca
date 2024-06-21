#!/bin/bash
export UPIN=123456 # default
export APIN=12345678 # default
export GPGHOME=/.gpg

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
    umount $GPGHOME &>/dev/null 
    cryptsetup luksClose keyringvol &>/dev/null
    ok
    info "Backing out Keystore to shared volume. "
    mv /KEYVOL /pgp-ca/ && ok
  fi
  exit $2
}

function fail(){
  echo -e "\033[31m[failed]\033[m" >&2
}

function ok(){
  echo -e "\033[32m[ok]\033[m" >&2
}

function rcStat(){
  if [ $1 -eq 0 ]
  then
    ok
  else
    fail
  fi
}

function error(){
  echo -n -e "\033[31m[ERROR]\033[m $1 " >&2
}

function info(){
  echo -n -e "\033[35m[INFO]\033[m $1 " >&2
}

function warn(){
  echo -n -e "\033[33m[WARNING]\033[m $1 " >&2
}

function initialize(){
  info "Initializing KEYVOL.\n"
  read -s -p "  Passphrase for KEYVOL - leave empty to generate one: "
  PASSPHRASE={REPLY:-$(LC_ALL=C tr -dc 'A-Z1-9' < /dev/urandom | \
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
  mount /dev/mapper/keyringvol $GPGHOME || die "Failed to mount KEYVOL." 1
  rcStat $?
  info "  Preparing GPG config: "
  cp /gpg.conf $GPGHOME/ &>/dev/null || die "Failed to prepare GPG config." 1
  rcStat $?
  info "This is the keystore's encryption passphrase: \033[31m$PASSPHRASE\033[m\n"
  warn "Make sure to note this passphrase down and store it securely!\n"
}

function mountKeystore(){
  read -s -p "Passphrase for keystore: " PASSPHRASE
  echo >&2
  info "Checking out and decrypting Keystore"
  cp /pgp-ca/KEYVOL /
  echo $PASSPHRASE | cryptsetup luksOpen /KEYVOL keyringvol - || { error "Failed to decrypt Keystore. Maybe bad passphrase?"; return 1; }
  rcStat $?
  info "Mounting Keystore"
  mount /dev/mapper/keyringvol $GPGHOME || { error "Failed to mount Keystore."; return 1; }	 
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
  info "Found yubikey with serial: $ykserial\n"
  return 0
}

function pgpMakeCkey(){
  info "Preparing for a new certify key:\n"
  CERTIFY_PASS=$(LC_ALL=C tr -dc 'A-Z1-9' < /dev/urandom | \
	  tr -d "1IOS5U" | fold -w 30 | sed "-es/./ /"{1..26..5} | \
	  cut -c2- | tr " " "-" | head -1) 
  info "This is the certify key's passphrase: \033[31m$CERTIFY_PASS\033[m\n"
  warn "Make sure to note this passphrase down and store it securely!\n"
  info "Creating new certify key: "
  gpg --batch --passphrase "$CERTIFY_PASS" --quick-generate-key "$IDENTITY" "$KEY_TYPE" cert never &>/gpg.log || die "Failed to create key." 100
  rcStat $?
  KEYID=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^pub:/ { print $5; exit }')
  KEYFP=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^fpr:/ { print $10; exit }')
  printf "\nKey ID: %40s\nKey FP: %40s\n\n" "$KEYID" "$KEYFP"
  info "Certify key created successfully.\n"
  info "This was gpg's output:\n"
  echo -e "\033[34m"
  cat /gpg.log
  echo -e "\033[m"
  info "Backing up certify key to $GPGHOME/$KEYID-Certify.key: "
  gpg --output $GPGHOME/$KEYID-Certify.key --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --armor --export-secret-keys $KEYID
  rcStat $?
}

function pgpMakeEASkeys(){
  :>/gpg.log
  KEYID=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^pub:/ { print $5; exit }')
  KEYFP=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^fpr:/ { print $10; exit }')
  info "Creating new subkeys for encryption, authentication and signing:\n"
  read -p "Please provide certify key's passphrase: " CERTIFY_PASS
  for SUBKEY in sign encrypt auth 
  do
	  info "  creating $SUBKEY key: "
	  gpg --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --quick-add-key "$KEYFP" "$KEY_TYPE" "$SUBKEY" "$EXPIRATION" &>>/gpg.log
    rcStat $?
  done
  info "This was gpg's output:\n"
  echo -e "\033[34m"
  cat /gpg.log
  echo -e "\033[m"
  info "The following keys do now exist: \n"
  gpg -K
  info "Backing up subkeys to $GPGHOME/$(date +%Y-%m-%d)_$KEYID-Subkeys.key: "
  gpg --output $GPGHOME/$(date +%Y-%m-%d)_$KEYID-Subkeys.key --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --armor --export-secret-subkeys $KEYID
  rcStat $?
}

function pgpRevKey(){
  KEYID=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^pub:/ { print $5; exit }')
  warn "This will revoke all your subkeys and export revoked keys to a keyserver.\n"
  warn "THIS CANNOT BE UNDONE!\n"
  read -p "Type YES (all uppercase) to continue: "
  [ "$REPLY" != "YES" ] && return 1
  read -p "Please provide certify key's passphrase: " CERTIFY_PASS
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
  info "Publishing revoked key ID $KEYID to keyserver $KEYSERVER: "
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
  read -p "Please provide certify key's passphrase: " CERTIFY_PASS
  read -p "Please enter expiration in years: " EXP
  info "Starting key edit: " 
  gpg --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --quick-set-expire "$KEYFP" "$EXP" "*" &>/dev/null
#  gpg --command-fd=0 --batch --pinentry-mode=loopback --passphrase "$CERTIFY_PASS" --edit-key $KEYID &>/dev/null <<EOF
#key 1
#key 2
#key 3
#expire
#y
#${EXP}y
#y
#save
#EOF
  if rcStat $?
  then
    pgpExportKey $(date +%Y-%m-%d).pub.asc
  fi
}

function pgpExportKey(){
  KEYID=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^pub:/ { print $5; exit }')
  info "Exporting public key ID $KEYID: "
  gpg --export --armor "$KEYID" > /pgp-ca/${KEYID}.$1  
  if rcStat $? 
  then
    info "Public key can now be found in mounted volume (${KEYID}.$1)"
    return 0
  else
    return 1
  fi
}

function ykChangePIN(){
  checkYK || return 1
  warn "This will change DEFAULT user and admin PINs of your yubikey's openpgp interface!\n"
  warn "Type YES (all uppercase) to continue: "
  read ans
  echo >&2
  if [ "$ans" = "YES" ]
  then
    read -p "New user PIN - Leave empty to generate a random one: " 
    UPIN=${REPLY:-$(LC_ALL=C tr -dc '0-9' < /dev/urandom | fold -w6 | head -1)}
    read -p "New admin PIN - Leave empty to generate a random one: " 
    APIN=${REPLY:-$(LC_ALL=C tr -dc '0-9' < /dev/urandom | fold -w8 | head -1)}
    info "Setting admin PIN to $APIN: "
    ykman openpgp access change-admin-pin 2>/dev/null <<EOF 
12345678
$APIN
$APIN
EOF
    rcStat $?
    info "Setting user PIN to $UPIN: "
    ykman openpgp access change-pin 2>/dev/null <<EOF
123456
$UPIN
$UPIN
EOF
    if rcStat $?
    then
      if [ -r $GPGHOME/yubikey-$ykserial.txt ]
      then
        grep -v PIN $GPGHOME/yubikey-$ykserial.txt > $GPGHOME/yubikey-$ykserial.txt
          cat <<EOF >>$GPGHOME/yubikey-$ykserial.txt
Admin PIN: $APIN
Initial user PIN: $UPIN
EOF
      else
         cat <<EOF >$GPGHOME/yubikey-$ykserial.txt
Cardholder Name: $YKCHOLDER 
Cardholder Email: $YKLOGIN
Admin PIN: $APIN
Initial user PIN: $UPIN
PGP Key ID: $KEYID
EOF
      fi
    fi
  fi
}

function ykReset(){
  checkYK || return 1
  warn "This will reset the yubikey's openpgp application to factory default!\n"
  warn "Type YES (all uppercase) to continue: "
  read ans
  echo >&2
  if [ "$ans" = "YES" ]
  then
    info "Resetting yubikey: " 
    out=$(echo "y" | ykman openpgp reset 2>/dev/null)
    rcStat $?
    echo $out
    rm $GPGHOME/yubikey-$ykserial.txt &>/dev/null
  fi
}

function ykProvision(){
  KEYID=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^pub:/ { print $5; exit }')
  checkYK || return 1
  info "Personalizing yubikey for identity $IDENTITY: \n"
  read -p "Cardholder's full name: " YKCHOLDER
  read -p "Cardholder's email address: " YKLOGIN
  read -p "Yubikey admin PIN: " APIN
  read -p "PGP certification passphrase: " CERTIFYPASS

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
  cat <<EOF >$GPGHOME/yubikey-$ykserial.txt
Cardholder Name: $YKCHOLDER 
Cardholder Email: $YKLOGIN
Admin PIN: $APIN
Initial user PIN: $UPIN
PGP Key ID: $KEYID
EOF
  info "Writing subkeys of key ID $KEYID to yubikey. \n"
  info "Exporting signature key: "
  cat <<EOF > /tmp/gpg-cmd
key 1
keytocard
1
EOF
  gpg --command-file /tmp/gpg-cmd --edit-key $KEYID 2>/dev/null 
  rcStat $? || die "Could not provison key to yubikey."

  info "Exporting encryption key: "
  cat <<EOF > /tmp/gpg-cmd
key 2
keytocard
2
EOF
  gpg --command-file /tmp/gpg-cmd --edit-key $KEYID 2>/dev/null 
  rcStat $? || die "Could not provison key to yubikey."

  info "Exporting authentication key: "
   cat <<EOF > /tmp/gpg-cmd
key 3
keytocard
3
EOF
  gpg --command-file /tmp/gpg-cmd --edit-key $KEYID 2>/dev/null 
  rcStat $? || die "Could not provison key to yubikey."
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
  echo -e "\033[36m" >&2
  cat <<EOF >&2
  Please choose from the following options:
  1) Create a new certification key
  2) Create and certify new EAS subkeys
  3) List keys in keyring
  4) Export public key
  5) Reset yubikey to factory default 
  6) Set yubikey PINs
  7) Provison keys to yubikey
  8) Export keys to keyserver
  9) Change EAS subkeys' expiration date
  R) Revoke EAS subkeys
  p) Print yubikey info
  s) Open an interactive shell
  e) Clean up and exit 
EOF
  echo -e "\033[m"
  read -n 1 -p "Your choice: " cmd
  echo >&2
  case $cmd in
    "e")
      info "Unmounting keystore"
      pkill scdaemon
      pkill gpg-agent
      pkill pcscd
      sleep 1
      cd / && umount $GPGHOME && cryptsetup luksClose keyringvol
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
      echo -e "\033[34m"
      gpg -K
      echo -e "\033[m"
    ;;
    "4")
      pgpExportKey
    ;;
    "5")
      ykReset
    ;;
    "6")
      ykChangePIN
    ;;
    "7")
      ykProvision
    ;;
    "8")
      KEYID=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^pub:/ { print $5; exit }')
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
        if [ -r $GPGHOME/yubikey-$ykserial.txt ]
        then
          info "This is the configuration of currently detected yubikey:\n"
          echo -e "\033[36m"
          cat $GPGHOME/yubikey-$ykserial.txt
          echo -e "\033[m"
        else
          warn "No configuration found for key with serial $ykserial!\n"
        fi
      fi
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
done
