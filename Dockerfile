FROM quay.io/wildfly/wildfly:41.0.1.Final-jdk21

LABEL org.opencontainers.image.source="https://github.com/GmelaN/memoharbor"
USER 0
# Trust forwarding headers only behind the OKD router. Management stays on localhost.
RUN /opt/jboss/wildfly/bin/jboss-cli.sh --commands="embed-server --std-out=echo,/subsystem=undertow/server=default-server/http-listener=default:write-attribute(name=proxy-address-forwarding,value=true),stop-embedded-server" \
    && chgrp -R 0 /opt/jboss/wildfly/standalone \
    && chmod -R g=u /opt/jboss/wildfly/standalone
COPY --chown=1000:0 target/memoharbor.war /opt/jboss/wildfly/standalone/deployments/memoharbor.war
RUN chmod g+r /opt/jboss/wildfly/standalone/deployments/memoharbor.war
USER 1000
EXPOSE 8080
CMD ["/opt/jboss/wildfly/bin/standalone.sh", "-b", "0.0.0.0"]
