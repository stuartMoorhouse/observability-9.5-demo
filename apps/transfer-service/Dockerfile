# transfer-service (Java 21, Spring Boot). No OTel SDK: the Java agent is injected by the OTel Operator.
FROM maven:3.9.16-eclipse-temurin-21-noble AS build
WORKDIR /src
COPY pom.xml ./
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q -DskipTests package

FROM eclipse-temurin:21.0.12.1_1-jre-noble
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --no-create-home app
WORKDIR /app
COPY --from=build --chown=10001:10001 /src/target/transfer-service.jar ./app.jar
USER 10001
EXPOSE 8080
# JAVA_TOOL_OPTIONS is left free for the operator-injected -javaagent flag
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-Djava.io.tmpdir=/tmp", "-jar", "/app/app.jar"]
