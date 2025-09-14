# pgp-ca Runtime System
FROM debian:sid

RUN apt update && apt -y upgrade && apt -y install e2fsprogs procps wget gnupg2 gnupg-agent dirmngr cryptsetup scdaemon pcscd yubikey-personalization yubikey-manager
RUN mkdir /.gpg /pgp-ca

COPY pgp-ca.sh .
COPY gpg.conf .
COPY gpg-agent.conf .
COPY scdaemon.conf .
RUN chmod 755 /pgp-ca.sh
RUN chmod 600 /gpg.conf
RUN chmod 600 /gpg-agent.conf
RUN chmod 600 /scdaemon.conf
#
ENTRYPOINT ["/pgp-ca.sh"]
