/*
 * Mock replacement for Synology's libsynoame-license.so
 *
 * Exports every symbol from the original library. License-check functions
 * return 1 (success). All other functions are no-op stubs that return 0.
 *
 * Every call is logged to /tmp/synoame-mock.log so you can verify which
 * functions DSM actually invokes at runtime. Remove or disable the logging
 * once testing is done.
 */

#include <stdio.h>
#include <string.h>
#include <time.h>

static void logcall(const char *name) {
    FILE *f = fopen("/tmp/synoame-mock.log", "a");
    if (f) {
        time_t t = time(NULL);
        struct tm *tm = localtime(&t);
        char ts[32];
        strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", tm);
        fprintf(f, "[%s] %s called\n", ts, name);
        fclose(f);
    }
}

/* ── License-check functions (return 1 = valid) ────────────────────── */

/* synoame::license::LicenseManager::IsValidStatus(Json::Value const&) const */
int _ZNK7synoame7license14LicenseManager13IsValidStatusERKN4Json5ValueE(
        void *this, void *json) {
    logcall("IsValidStatus");
    return 1;
}

/* synoame::license::LicenseManager::ValidateLicense(Json::Value const&) const */
int _ZNK7synoame7license14LicenseManager15ValidateLicenseERKN4Json5ValueE(
        void *this, void *json) {
    logcall("ValidateLicense");
    return 1;
}

/* synoame::license::LicenseManager::CheckLicense() const */
int _ZNK7synoame7license14LicenseManager12CheckLicenseEv(void *this) {
    logcall("CheckLicense");
    return 1;
}

/* synoame::license::LicenseManager::CheckOfflineLicense() const */
int _ZNK7synoame7license14LicenseManager19CheckOfflineLicenseEv(void *this) {
    logcall("CheckOfflineLicense");
    return 1;
}

/* SLIsXA */
int SLIsXA(void) {
    logcall("SLIsXA");
    return 1;
}

/* ── C API stubs (return 0 / no-op) ────────────────────────────────── */

int SLCodeActivate(void)        { logcall("SLCodeActivate");     return 0; }
int SLCodeDeactivate(void)      { logcall("SLCodeDeactivate");   return 0; }
int SLCodeListByDevice(void)    { logcall("SLCodeListByDevice"); return 0; }
int SLCodeListBySerial(void)    { logcall("SLCodeListBySerial"); return 0; }
int SLCodeListByUUID(void)      { logcall("SLCodeListByUUID");   return 0; }
int SLErrCodeGet(void)          { logcall("SLErrCodeGet");       return 0; }
void SLErrCodeSet(int code)     { logcall("SLErrCodeSet"); }
int SLGetAccountInfo(void)      { logcall("SLGetAccountInfo");   return 0; }
int SLGetUUID(void)             { logcall("SLGetUUID");          return 0; }
int SLOfflineCodeList(void)     { logcall("SLOfflineCodeList");  return 0; }
int SLRecovery(void)            { logcall("SLRecovery");         return 0; }
int SLSaveVault(void)           { logcall("SLSaveVault");        return 0; }
int SLSendAPI(void)             { logcall("SLSendAPI");          return 0; }
int SLUserLogin(void)           { logcall("SLUserLogin");        return 0; }
int SLUserLogout(void)          { logcall("SLUserLogout");       return 0; }
int SLUserTryLogin(void)        { logcall("SLUserTryLogin");     return 0; }

int Base64Decode(void)          { logcall("Base64Decode");       return 0; }
int Base64Encode(void)          { logcall("Base64Encode");       return 0; }
int baseURL(void)               { logcall("baseURL");            return 0; }

/* ── C++ class stubs ───────────────────────────────────────────────── */

/* LicenseManager::LicenseManager(string const&, string const&, string const&) */
void _ZN7synoame7license14LicenseManagerC1ERKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEES9_S9_(
        void *this, void *a, void *b, void *c) {
    logcall("LicenseManager::LicenseManager");
}
void _ZN7synoame7license14LicenseManagerC2ERKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEES9_S9_(
        void *this, void *a, void *b, void *c) {
    logcall("LicenseManager::LicenseManager");
}

/* LicenseManager::Create() */
int _ZN7synoame7license14LicenseManager6CreateEv(void *this) {
    logcall("LicenseManager::Create");
    return 0;
}

/* LicenseManager::RegisterAndActivateFreeLicense(string const&) */
int _ZN7synoame7license14LicenseManager30RegisterAndActivateFreeLicenseERKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEE(
        void *this, void *str) {
    logcall("LicenseManager::RegisterAndActivateFreeLicense");
    return 0;
}

/* LicenseManager::DoPutRequest(cpr::Url const&, cpr::Payload const&) const */
int _ZNK7synoame7license14LicenseManager12DoPutRequestERKN3cpr3UrlERKNS2_7PayloadE(
        void *this, void *url, void *payload) {
    logcall("LicenseManager::DoPutRequest");
    return 0;
}

/* LicenseManager::GetFirstLicense(Json::Value const&, Json::Value&) const */
int _ZNK7synoame7license14LicenseManager15GetFirstLicenseERKN4Json5ValueERS3_(
        void *this, void *in, void *out) {
    logcall("LicenseManager::GetFirstLicense");
    return 0;
}

/* LicenseManager::GetLicenseOnline(Json::Value&) const */
int _ZNK7synoame7license14LicenseManager16GetLicenseOnlineERN4Json5ValueE(
        void *this, void *json) {
    logcall("LicenseManager::GetLicenseOnline");
    return 0;
}

/* LicenseManager::GetLicenseOffline(Json::Value&) const */
int _ZNK7synoame7license14LicenseManager17GetLicenseOfflineERN4Json5ValueE(
        void *this, void *json) {
    logcall("LicenseManager::GetLicenseOffline");
    return 0;
}

/* LicenseManager::GeneratePaymentApiUrl(string const&) const */
int _ZNK7synoame7license14LicenseManager21GeneratePaymentApiUrlERKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEE(
        void *this, void *str) {
    logcall("LicenseManager::GeneratePaymentApiUrl");
    return 0;
}

/* ── Payload class stubs ───────────────────────────────────────────── */

int _ZN7Payload12getMachinePKEP11synopki_ctx(void *this, void *ctx) {
    logcall("Payload::getMachinePK");
    return 0;
}

int _ZN7Payload13getDeviceInfoEv(void *this) {
    logcall("Payload::getDeviceInfo");
    return 0;
}

int _ZN7Payload14getAccountInfoEv(void *this) {
    logcall("Payload::getAccountInfo");
    return 0;
}

int _ZN7Payload6asJsonEv(void *this) {
    logcall("Payload::asJson");
    return 0;
}
