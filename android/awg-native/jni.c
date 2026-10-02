/* SPDX-License-Identifier: Apache-2.0
 *
 * Copyright © 2017-2021 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

#include <jni.h>
#include <stdlib.h>
#include <string.h>

struct go_string { const char *str; long n; };
extern int awgTurnOn(struct go_string ifname, int tun_fd, struct go_string settings);
extern void awgTurnOff(int handle);
extern int awgGetSocketV4(int handle);
extern int awgGetSocketV6(int handle);
extern char *awgGetConfig(int handle);
extern char *awgVersion();
extern int awgStartStream(struct go_string spec);
extern void awgStopStream(int handle);

/* The live VpnService, used to protect the stream bridge's TLS socket from the
 * tunnel it carries. Registered by the Java side when the AWG VpnService is
 * created; a null service makes awgProtectSocket fail, which fails the dial
 * closed rather than letting it leak into the tunnel. */
static JavaVM *g_vm = NULL;
static jobject g_vpn_service = NULL;
static jmethodID g_protect_method = NULL;

int awgProtectSocket(int fd)
{
	if (g_vm == NULL || g_vpn_service == NULL || g_protect_method == NULL)
		return 0;
	JNIEnv *env = NULL;
	if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
		if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK)
			return 0;
	}
	jboolean ok = (*env)->CallBooleanMethod(env, g_vpn_service, g_protect_method, (jint)fd);
	if ((*env)->ExceptionCheck(env)) {
		(*env)->ExceptionClear(env);
		return 0;
	}
	return ok == JNI_TRUE ? 1 : 0;
}

JNIEXPORT void JNICALL Java_com_boltmesh_boltmesh_StreamSocketProtector_nativeAttach(JNIEnv *env, jclass c, jobject service)
{
	(void)c;
	if ((*env)->GetJavaVM(env, &g_vm) != JNI_OK)
		g_vm = NULL;
	if (g_vpn_service != NULL)
		(*env)->DeleteGlobalRef(env, g_vpn_service);
	g_vpn_service = (*env)->NewGlobalRef(env, service);
	if (g_protect_method == NULL) {
		jclass cls = (*env)->GetObjectClass(env, service);
		g_protect_method = (*env)->GetMethodID(env, cls, "protect", "(I)Z");
	}
}

JNIEXPORT void JNICALL Java_com_boltmesh_boltmesh_StreamSocketProtector_nativeDetach(JNIEnv *env, jclass c, jobject service)
{
	(void)c;
	if (g_vpn_service != NULL && (*env)->IsSameObject(env, g_vpn_service, service)) {
		(*env)->DeleteGlobalRef(env, g_vpn_service);
		g_vpn_service = NULL;
	}
}


JNIEXPORT jint JNICALL Java_org_amnezia_awg_GoBackend_awgTurnOn(JNIEnv *env, jclass c, jstring ifname, jint tun_fd, jstring settings)
{
	const char *ifname_str = (*env)->GetStringUTFChars(env, ifname, 0);
	size_t ifname_len = (*env)->GetStringUTFLength(env, ifname);
	const char *settings_str = (*env)->GetStringUTFChars(env, settings, 0);
	size_t settings_len = (*env)->GetStringUTFLength(env, settings);
	int ret = awgTurnOn((struct go_string){
		.str = ifname_str,
		.n = ifname_len
	}, tun_fd, (struct go_string){
		.str = settings_str,
		.n = settings_len
	});
	(*env)->ReleaseStringUTFChars(env, ifname, ifname_str);
	(*env)->ReleaseStringUTFChars(env, settings, settings_str);
	return ret;
}

JNIEXPORT void JNICALL Java_org_amnezia_awg_GoBackend_awgTurnOff(JNIEnv *env, jclass c, jint handle)
{
	awgTurnOff(handle);
}

JNIEXPORT jint JNICALL Java_org_amnezia_awg_GoBackend_awgGetSocketV4(JNIEnv *env, jclass c, jint handle)
{
	return awgGetSocketV4(handle);
}

JNIEXPORT jint JNICALL Java_org_amnezia_awg_GoBackend_awgGetSocketV6(JNIEnv *env, jclass c, jint handle)
{
	return awgGetSocketV6(handle);
}

JNIEXPORT jstring JNICALL Java_org_amnezia_awg_GoBackend_awgGetConfig(JNIEnv *env, jclass c, jint handle)
{
	jstring ret;
	char *config = awgGetConfig(handle);
	if (!config)
		return NULL;
	ret = (*env)->NewStringUTF(env, config);
	free(config);
	return ret;
}

JNIEXPORT jstring JNICALL Java_org_amnezia_awg_GoBackend_awgVersion(JNIEnv *env, jclass c)
{
	jstring ret;
	char *version = awgVersion();
	if (!version)
		return NULL;
	ret = (*env)->NewStringUTF(env, version);
	free(version);
	return ret;
}

JNIEXPORT jint JNICALL Java_org_amnezia_awg_GoBackend_awgStartStream(JNIEnv *env, jclass c, jstring spec)
{
	(void)c;
	const char *spec_str = (*env)->GetStringUTFChars(env, spec, 0);
	size_t spec_len = (*env)->GetStringUTFLength(env, spec);
	int ret = awgStartStream((struct go_string){
		.str = spec_str,
		.n = spec_len
	});
	(*env)->ReleaseStringUTFChars(env, spec, spec_str);
	return ret;
}

JNIEXPORT void JNICALL Java_org_amnezia_awg_GoBackend_awgStopStream(JNIEnv *env, jclass c, jint handle)
{
	(void)env;
	(void)c;
	awgStopStream(handle);
}
