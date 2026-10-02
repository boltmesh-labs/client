# AndroidJUnitRunner discovers some support classes by name at runtime. The
# release androidTest APK is minified along with the app, so keep its runner
# graph intact instead of letting R8 remove classes that have no direct call
# site in the tests.
-keep class androidx.test.** { *; }
