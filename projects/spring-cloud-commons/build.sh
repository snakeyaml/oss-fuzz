#!/bin/bash -eu
# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

mv $SRC/*.dict $OUT

export JAVA_HOME="$OUT/open-jdk-17"
mkdir -p $JAVA_HOME
rsync -aL --exclude=*.zip "/usr/lib/jvm/java-17-openjdk-amd64/" "$JAVA_HOME"

cat > patch.diff <<- EOM
diff --git a/pom.xml b/pom.xml
index 831f5a1..855a43e 100644
--- a/pom.xml
+++ b/pom.xml
@@ -61,10 +74,6 @@
 				<groupId>io.spring.javaformat</groupId>
 				<artifactId>spring-javaformat-maven-plugin</artifactId>
 			</plugin>
-			<plugin>
-				<groupId>org.apache.maven.plugins</groupId>
-				<artifactId>maven-checkstyle-plugin</artifactId>
-			</plugin>
 			<plugin>
 				<groupId>org.basepom.maven</groupId>
 				<artifactId>duplicate-finder-maven-plugin</artifactId>
@@ -74,10 +83,6 @@
 
 	<reporting>
 		<plugins>
-			<plugin>
-				<groupId>org.apache.maven.plugins</groupId>
-				<artifactId>maven-checkstyle-plugin</artifactId>
-			</plugin>
 		</plugins>
 	</reporting>
 

EOM

git apply patch.diff -v

MAVEN_ARGS="-Djavac.src.version=17 -Djavac.target.version=17 -DskipTests -Dcheckstyle.skip=true"
CURRENT_VERSION=$($MVN org.apache.maven.plugins:maven-help-plugin:3.2.0:evaluate \
 -Dexpression=project.version -q -DforceStdout)

$MVN clean package $MAVEN_ARGS
$MVN package org.apache.maven.plugins:maven-shade-plugin:3.2.4:shade $MAVEN_ARGS
cp "spring-cloud-commons/target/spring-cloud-commons-$CURRENT_VERSION.jar" "$OUT/spring-cloud-commons.jar"
cp "spring-cloud-context/target/spring-cloud-context-$CURRENT_VERSION.jar" "$OUT/spring-cloud-context.jar"
cp "spring-cloud-starter-bootstrap/target/spring-cloud-starter-bootstrap-$CURRENT_VERSION.jar" "$OUT/spring-cloud-starter-bootstrap.jar"

ALL_JARS="spring-cloud-commons.jar spring-cloud-context.jar spring-cloud-starter-bootstrap.jar"

# The classpath at build-time includes the project jars in $OUT as well as the
# Jazzer API.
BUILD_CLASSPATH=$(echo $ALL_JARS | xargs printf -- "$OUT/%s:"):$JAZZER_API_PATH

# All .jar and .class files lie in the same directory as the fuzzer at runtime.
RUNTIME_CLASSPATH=$(echo $ALL_JARS | xargs printf -- "\$this_dir/%s:"):\$this_dir

for fuzzer in $(find $SRC -name '*Fuzzer.java'); do
  fuzzer_basename=$(basename -s .java $fuzzer)
  javac -cp $BUILD_CLASSPATH $fuzzer --release 17
  cp $SRC/$fuzzer_basename.class $OUT/

  # Create an execution wrapper that executes Jazzer with the correct arguments.
  echo "#!/bin/sh
# LLVMFuzzerTestOneInput for fuzzer detection.
this_dir=\$(dirname \"\$0\")
JAVA_HOME=\"\$this_dir/open-jdk-17/\" \
LD_LIBRARY_PATH=\"\$this_dir/open-jdk-17/lib/server\":\$this_dir \
\$this_dir/jazzer_driver --agent_path=\$this_dir/jazzer_agent_deploy.jar \
--instrumentation_excludes=org.springframework.security.**:org.bouncycastle.** \
--cp=$RUNTIME_CLASSPATH \
--target_class=$fuzzer_basename \
--jvm_args=\"-Xmx2048m\" \
\$@" > $OUT/$fuzzer_basename
  chmod u+x $OUT/$fuzzer_basename
done 