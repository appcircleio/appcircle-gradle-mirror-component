# Appcircle Gradle Mirror

This step points every Gradle build of the workflow at a Maven repository on your artifact proxy (for example a Sonatype Nexus or JFrog Artifactory group), so Android, React Native and Flutter builds work on runners without internet access.

Place it **after Git Clone** and before the steps that run Gradle. It writes the Gradle configuration of the runner (the Gradle user home) and checks the project's Gradle wrapper (see [What You Configure in the Project](#what-you-configure-in-the-project)). If `AC_MIRROR_GRADLE` is empty, the step does nothing.

Supported: Gradle 7.0 and later.

## Optional Input Variables

- `$AC_MIRROR_GRADLE`: URL of a Maven repository on your artifact proxy, usually a group (see [Artifact Proxy Setup](#artifact-proxy-setup)). Every remote repository of the build is sent to it. If empty, the step does nothing.
- `$AC_MIRROR_GRADLE_DISTRIBUTION`: URL of a raw (generic) repository on your artifact proxy that proxies `https://services.gradle.org/`. Used when Gradle Wrapper is `update`.
- Gradle Wrapper (`update`, `fail` or `warn`, default `fail`): what the step does when a `gradle-wrapper.properties` of the project still downloads Gradle from services.gradle.org. Set it on the step, not in the group: it depends on the project.
- `$AC_MIRROR_GRADLE_USERNAME`: User for the Gradle mirror.
- `$AC_MIRROR_GRADLE_PASSWORD`: Password for the Gradle mirror user. Store it as a secret environment variable.
- `$AC_MIRROR_USERNAME`: User shared by all mirror steps. Used when both Gradle mirror credentials are empty.
- `$AC_MIRROR_PASSWORD`: Password of the shared mirror user. Store it as a secret environment variable.

Set the values once in an Environment Variable Group and add the group to the configurations that use the step. The Gradle credentials replace the shared credentials as a pair; if only one value of a pair is set, the step fails.

## What the Step Does

- Writes an init script to `$GRADLE_USER_HOME/init.d/appcircle-mirror.gradle` (default `~/.gradle`). For every build it sends each remote Maven repository to `AC_MIRROR_GRADLE`: settings `pluginManagement` and `dependencyResolutionManagement`, `buildscript` and project repositories, included builds and `buildSrc`. It also adds the mirror for plugins that rely on the Gradle Plugin Portal by default.
- Leaves alone:
  - local repositories, such as `mavenLocal()` and `file:` repositories;
  - repositories that already point at the host of your artifact proxy. An example is Flutter's engine repository when `FLUTTER_STORAGE_BASE_URL` points at the proxy.
- Sends the credentials with the first request (basic authentication), so a proxy that also allows anonymous reads still sees the user.
- Passes these settings to the later steps of the same build only:
  - `AC_MIRROR_GRADLE` and, with credentials, the chosen pair as `AC_MIRROR_GRADLE_USERNAME` / `AC_MIRROR_GRADLE_PASSWORD`, which the init script reads when Gradle runs. Step inputs reach only the step itself, so this also covers values typed into the inputs instead of taken from a group;
  - `ORG_GRADLE_PROJECT_skipDependencyChecks=true`, for the Flutter Gradle plugin, whose dependency checker declares repositories an init script cannot reach;
  - with credentials, `-Dgradle.wrapperUser` and `-Dgradle.wrapperPassword` in `GRADLE_OPTS`, so the Gradle wrapper can download from an authenticated proxy.
- Logs one line per redirected repository, for example `Gradle Mirror: Google https://dl.google.com/dl/android/maven2/ -> https://nexus.example.com/repository/maven-public/`. Passwords are never logged.

## Runners That Keep Their State

The step can run on every build of a runner that is not recreated between builds:

- It writes the same init script every time. The file holds no URL and no password: it reads them from the build's environment, so it does nothing for builds that do not use the step (no `AC_MIRROR_GRADLE` in their environment).
- It does not write `gradle.properties` or any other file with a password. Credentials reach Gradle only through the environment of the current build.

## What You Configure in the Project

The Gradle wrapper downloads Gradle before any init script runs, so it uses the `distributionUrl` in `gradle/wrapper/gradle-wrapper.properties`. The step checks every wrapper of the cloned project (`node_modules` and build folders excluded):

- A wrapper that already downloads from your artifact proxy, or from any host other than services.gradle.org, is left as it is.
- A wrapper that downloads from services.gradle.org depends on the Gradle Wrapper input:
  - `update`: the step points `distributionUrl` at `AC_MIRROR_GRADLE_DISTRIBUTION` in the cloned copy and logs the change. Nothing is pushed back to your repository. `distributionSha256Sum` keeps working, because the proxy serves the same file.
  - `fail` (default): the build stops at once and names the file, instead of failing later on a connection timeout.
  - `warn`: the step prints a warning and the build continues.

To keep the project and your developers' machines on the proxy as well, set `distributionUrl` in the project:

```properties
distributionUrl=https\://nexus.example.com/repository/gradle-distributions/distributions/gradle-8.11.1-bin.zip
```

## Artifact Proxy Setup

Create one Maven group that contains every upstream your projects use, and use the group URL as `AC_MIRROR_GRADLE`. Recommended members, in this order:

| Upstream | Remote URL | Needed by |
| --- | --- | --- |
| Google Maven | `https://dl.google.com/dl/android/maven2/` | Every Android project. Keep it first, it serves most Android artifacts |
| Maven Central | `https://repo1.maven.org/maven2/` | Every project |
| Gradle Plugin Portal | `https://plugins.gradle.org/m2/` | Projects that use the `plugins {}` block |
| Flutter engine | `https://storage.googleapis.com/download.flutter.io/` | Flutter projects |
| JitPack | `https://jitpack.io/` | Only projects that use it |
| Vendor repositories | for example `https://developer.huawei.com/repo/` | Only projects that use them |

For the Gradle wrapper, add a separate raw (generic) proxy of `https://services.gradle.org/`.

The upstreams redirect to other hosts, which your proxy must be able to reach:

- `plugins.gradle.org` redirects to `repo.maven.apache.org` and `plugins-artifacts.gradle.org`.
- `services.gradle.org` redirects to `github.com` and `release-assets.githubusercontent.com`.
- Maven Central redirects React Native artifacts to `repo.reactnative.dev`.

Give Appcircle a read-only user on these repositories.

## Find the Repositories Your Project Uses

Run [`tools/list-repositories.gradle`](tools/list-repositories.gradle) once on a machine where the build works (with internet access), with the task your Appcircle build runs:

```bash
./gradlew -I list-repositories.gradle app:bundleRelease --dry-run
```

It prints every remote Maven repository the build declares, including the ones plugins add while the build is configured:

```text
Repository: https://dl.google.com/dl/android/maven2/  (first declared in : buildscript, name 'Google')
Repository: https://repo.maven.apache.org/maven2/  (first declared in : buildscript, name 'MavenRepo')
Repository: https://plugins.gradle.org/m2  (first declared in : buildscript, name 'Gradle Central Plugin Repository')
Repository: https://jitpack.io  (first declared in :, name 'maven')
```

Every URL in the list must be served by your Maven group.

- Use the task of your real build: `<module>:bundle<Variant>` or `<module>:assemble<Variant>`, shown in the Android Build step log.
- If you build more than one flavor, list each flavor's task.
- `--dry-run` configures the build without running it.
- A URL can appear once per included build.

## Limits

- Script plugins applied with `apply from:` keep their own `buildscript` repositories.
- Android SDK packages that are missing on the runner (a platform, build-tools or NDK version) are downloaded by the Android Gradle Plugin from `dl.google.com/android/repository`, not through Maven. Set `buildToolsVersion` to a version installed on the runner, or install the package on the runner image.
- Java toolchains downloaded by the foojay resolver plugin are not covered. Use the Select Java Version step instead.
- Older `gradlew` scripts can change a backslash in the credentials before the wrapper reads them; the step warns when a credential contains one. Regenerate the wrapper with a current Gradle version (`gradle wrapper`) if the wrapper download fails with 401.
