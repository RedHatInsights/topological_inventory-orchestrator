FROM registry.access.redhat.com/ubi8/ubi:8.3-227

RUN dnf -y --disableplugin=subscription-manager module enable ruby:2.5 && \
    dnf -y --disableplugin=subscription-manager --setopt=tsflags=nodocs install \
      ruby-devel \
      # To compile native gem extensions
      gcc-c++ make redhat-rpm-config \
      # For git based gems
      git \
      # For checking service status
      nmap-ncat \
      && \
    dnf --disableplugin=subscription-manager clean all

ENV WORKDIR /opt/topological_inventory-orchestrator/
WORKDIR $WORKDIR
COPY . $WORKDIR

RUN echo "gem: --no-document" > ~/.gemrc && \
    gem install bundler --conservative --without development:test && \
    bundle install --jobs 8 --retry 3 && \
    find $(gem env gemdir)/gems/ | grep "\.s\?o$" | xargs rm -rvf && \
    rm -rvf $(gem env gemdir)/cache/* && \
    rm -rvf /root/.bundle/cache

RUN chgrp -R 0 $WORKDIR && \
    chmod -R g=u $WORKDIR

ENTRYPOINT ["bin/topological_inventory-orchestrator"]
