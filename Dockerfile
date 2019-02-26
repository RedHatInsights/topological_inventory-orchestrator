FROM manageiq/ruby:latest

RUN yum -y install centos-release-scl-rh && \
    yum -y install --setopt=tsflags=nodocs \
                   # To compile native gem extensions
                   gcc-c++ \
                   # For git based gems
                   git \
                   && \
    yum clean all

ENV WORKDIR /opt/topological_inventory-orchestrator/
WORKDIR $WORKDIR
COPY . $WORKDIR

RUN echo "gem: --no-document" > ~/.gemrc && \
    gem install bundler --conservative --without development:test && \
    bundle install --jobs 8 --retry 3 && \
    find ${RUBY_GEMS_ROOT}/gems/ | grep "\.s\?o$" | xargs rm -rvf && \
    rm -rvf ${RUBY_GEMS_ROOT}/cache/* && \
    rm -rvf /root/.bundle/cache

RUN chgrp -R 0 $WORKDIR && \
    chmod -R g=u $WORKDIR

ENTRYPOINT ["bin/topological_inventory-orchestrator"]
