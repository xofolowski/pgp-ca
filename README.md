# Overview
This work is based on drduh's incredibly good [YubiKey Guide](https://github.com/drduh/YubiKey-Guide).
It aims at making the steps described there as convenient as possible while still adhering to an acceptable security level.  
To achieve that, all cryptographic operations will be performed within a docker container and any results will only be persisted on a LUKS encrypted loopback device, which will be backed out to a docker mounted volume at termination of the container.

# Intention
This project was started to provide an easy-to-use setup for issuing of HW-token based PGP keys.  
It is a common issue that (security) teams have access to a shared mailbox, for which they also want to provide PGP encryption / signing capabilities.  
Usually, this is often solved by just copying the respective PGP secret keyring to every team member's PGPHOME.  
Any staff changes (movers, leavers) would then actually require revocation of the current and issuing of a new key, which is rarely being done on many teams.  

This project aims at solving that problem by
- splitting certification PGP keys and those actually used on a daily basis for encryption, authentication and signing (EAS)
- provisioning EAS keys on a physically controllable hardware token (YubiKey) that can be handed over to (and later on requested back from) authorized team members

Ideally, this would reduce the necessity of key revocation to occasions, where hardware tokens had been lost or cannot be requested back from the card holder for any other reasons. 
Reprovisioning of remaining tokens in such cases can easily be accomplished within one minute per token.

# Usage
1. Clone this repository to a docker enabled host
2. Build the container:
   ````
   # cd pgp-ca
   # docker compose build
    ````
3. Adjust contents of `data/conf/pgp-ca/pgp-ca.env` to your needs
4. Run the container:
   ````
   # docker compose run --rm pgp-ca
    ````
    If data/conf/pgp-ca/KEYVOL does not yet exist, pgp-ca will set it up and LUKS-encrypt it.
    Otherwise, pgp-ca will ask for the LUKS passphrase, decrypt and mount the KEYVOL.
    Afterwards it will present a menu with available options:

    ````
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
        s) Open an interactive shell
        e) Clean up and exit
    ````

    At least you should:  
    - Reset your YubiKey if it wasn't freshly unboxed
    - Set your YubiKey user and admin PINs
    - Create a new certification key
    - Create and certify subkeys for encryption, authentication and signature
    - export your public keys
    - provision keys to your YubiKey

# Known Errors and Glitches
- current version of GPG repeatedly fails when reading passphrases from STDIN, throwing a "timing error". Thus, the current implementation has to use the more inconvenient interactive passphrase prompt
- sometimes the KEYVOL cannot be unmounted and closed correctly. Subsequent runs of the container will then fail to decrypt and mount the KEYVOL. This can be solved by running `docker compose run pgp-ca prune` once
  
# Drawbacks
- container currently has to run in privileged mode for
  - LUKS setup
  - accessing an USB connected YubiKey
- container requires network access for keyserver operations 

# Credits
- [drduh](https://github.com/drduh)