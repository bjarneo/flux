/**
 * Google Maven is normally reached through dl.google.com. To use a mirror,
 * set the `googleMavenRepositoryUrl` Gradle property.
 */
pluginManagement {
    repositories {
        maven {
            url = uri(providers.gradleProperty("googleMavenRepositoryUrl")
                .getOrElse("https://dl.google.com/dl/android/maven2/"))
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven {
            url = uri(providers.gradleProperty("googleMavenRepositoryUrl")
                .getOrElse("https://dl.google.com/dl/android/maven2/"))
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
    }
}

rootProject.name = "flux"
include(":app")
