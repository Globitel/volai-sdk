plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

group = "com.globitel.volai"
version = "0.1.3"

android {
    namespace = "com.globitel.volai"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

// Maven Central (Central Portal). Credentials and the signing key come from
// ORG_GRADLE_PROJECT_mavenCentral{Username,Password} and
// ORG_GRADLE_PROJECT_signingInMemoryKey{,Id,Password} (CI secrets); without
// them the plugin still builds the publication for publishToMavenLocal.
mavenPublishing {
    publishToMavenCentral(automaticRelease = true)
    signAllPublications()
    coordinates("com.globitel.volai", "volai-sdk", version.toString())
    pom {
        name.set("Volai Android SDK")
        description.set("Android client for the Volai SDK contract: chat over REST and server-sent events, and voice as PCM over one WebSocket.")
        url.set("https://github.com/Globitel/volai-sdk")
        licenses {
            license {
                name.set("Apache-2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
            }
        }
        developers {
            developer {
                id.set("globitel")
                name.set("Globitel")
                url.set("https://github.com/Globitel")
            }
        }
        scm {
            url.set("https://github.com/Globitel/volai-sdk")
            connection.set("scm:git:https://github.com/Globitel/volai-sdk.git")
            developerConnection.set("scm:git:ssh://git@github.com/Globitel/volai-sdk.git")
        }
    }
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.0.21")
    testImplementation("org.json:json:20240303")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")

    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}
