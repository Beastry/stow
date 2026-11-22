# JAR editing fixtures

OpenJDK 21's `jar` built `Ordinary.jar` with text payloads and a nested
`lib/dependency.jar` containing `dep.txt`. OpenJDK's `jarsigner` built
`Signed.jar` from that file with `-digestalg SHA-256` and a self-signed RSA
test key whose alias was `stowfixture`. Only the public certificate and
public signature artifacts are included. `jarsigner -verify Signed.jar`
verifies the signature and reports the expected self-signed certificate
and absent timestamp. The native tests use the bundled archives directly.
The duplicate-directory fixture is constructed by `ZipFixture` in the test.
