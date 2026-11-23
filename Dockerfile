# Archon on Railway: the official Archon image, pinned by version and digest, plus a small start script.
# Bump the pin here (tag and digest together) and add a CHANGELOG.md entry; Railway then offers the update
# to everyone who deployed the template.
FROM ghcr.io/coleam00/archon:0.14.0@sha256:2e63db617c76fa4ab8c86f20b32815993473d42609f56236a79ede3b23aaefa1

ENV ARCHON_DOCKER=true

COPY railway-start.sh /usr/local/bin/railway-start.sh
RUN chmod 755 /usr/local/bin/railway-start.sh

# The image's own entrypoint (docker-entrypoint.sh) still runs: the start script hands over to it.
ENTRYPOINT ["/usr/local/bin/railway-start.sh"]
