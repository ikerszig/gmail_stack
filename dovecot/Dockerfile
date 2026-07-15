FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends dovecot-core dovecot-imapd && \
    rm -rf /var/lib/apt/lists/*

COPY conf/dovecot.conf /etc/dovecot/dovecot.conf

EXPOSE 993

CMD ["dovecot", "-F"]
