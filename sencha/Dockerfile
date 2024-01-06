FROM openjdk:8-jre-alpine

LABEL maintainer="pauelstv@gmail.com" \
  description="This image is building SENCHA builder for NAVI project " \
  VERSION="1.0.3"

RUN apk --no-cache add ruby build-base libstdc++ tzdata bash ttf-dejavu freetype fontconfig wget curl

ARG SENCHA_VERSION="7.6.0.87"

RUN wget http://cdn.sencha.com/cmd/$SENCHA_VERSION/no-jre/SenchaCmd-$SENCHA_VERSION-linux-amd64.sh.zip -O senchacmd.zip \
  && unzip senchacmd.zip \
  && rm senchacmd.zip \
  && chmod +x SenchaCmd-$SENCHA_VERSION-linux-amd64.sh \
  && ./SenchaCmd-$SENCHA_VERSION-linux-amd64.sh -q -dir /opt/Sencha/Cmd/$SENCHA_VERSION -Dall=true \
  && rm SenchaCmd-$SENCHA_VERSION-linux-amd64.sh \
  && chmod +x /opt/Sencha/Cmd/$SENCHA_VERSION/sencha


ENV PJS_HOME=/usr/lib/phantomjs
RUN cd /tmp && \
  curl -Ls "https://github.com/israelroldan/docker-sencha-cmd/raw/phantomjs-2.1.1/dockerized-phantomjs-2.1.1.tar.gz" | tar xz -C / && \
  ln -s "$PJS_HOME/bin/phantomjs" /usr/bin/phantomjs && \
  rm "/opt/Sencha/Cmd/$SENCHA_VERSION/bin/linux-x64/phantomjs/phantomjs" && \
  ln -s "$PJS_HOME/bin/phantomjs" "/opt/Sencha/Cmd/$SENCHA_VERSION/bin/linux-x64/phantomjs/phantomjs"

ENV PATH=$PATH:/opt/Sencha/Cmd/$SENCHA_VERSION/

CMD ["sencha"]