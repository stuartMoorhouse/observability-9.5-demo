# fraud-check (.NET 8). No OTel SDK: .NET auto-instrumentation is injected by the OTel Operator.
# Debian (glibc) runtime image -> operator runtime "linux-x64".
FROM mcr.microsoft.com/dotnet/sdk:8.0.426 AS build
WORKDIR /src
COPY FraudCheck.csproj ./
RUN dotnet restore FraudCheck.csproj
COPY Program.cs ./
RUN dotnet publish FraudCheck.csproj -c Release -o /out --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0.32
WORKDIR /app
COPY --from=build --chown=1654:1654 /out ./
ENV ASPNETCORE_ENVIRONMENT=Production PORT=8080 DOTNET_gcServer=0
# "app" user (uid 1654) ships with the official .NET 8 images
USER 1654
EXPOSE 8080
ENTRYPOINT ["dotnet", "FraudCheck.dll"]
