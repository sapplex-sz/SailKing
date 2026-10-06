#pragma once
#include <cstdint>
#include <array>
#include <string>
#include <algorithm>
// Fixed-width UTF-16 wire format: identical for 32-bit and 64-bit TSF clients.
namespace sailking {
constexpr uint32_t magic = 0x534B494D, version = 1;
enum class Operation : uint32_t { status, key, select, reset, close, toggleEnglish, toggleTranslation, translateText, cancel, commitOriginal, shutdown };
enum class Job : uint32_t { idle, running, ready, failed };
#pragma pack(push, 4)
struct Request {
    uint32_t signature = magic, protocol = version;
    std::array<uint8_t,16> session{};
    Operation operation = Operation::status;
    uint32_t key = 0, modifiers = 0;
    char16_t text[4096]{};
    char16_t source[32]{};
    char16_t target[32]{};
};
struct Response {
    uint32_t signature = magic, protocol = version;
    uint32_t available = 0, handled = 0, english = 0, translation = 0;
    Job job = Job::idle;
    int32_t selected = 0, count = 0;
    char16_t preedit[1024]{}, draft[4096]{}, commit[8192]{}, result[8192]{}, error[256]{};
    char16_t candidates[9][128]{};
};
#pragma pack(pop)
static_assert(sizeof(Request)==8356);
static_assert(sizeof(Response)==45860);
template<size_t N> bool copy(char16_t (&to)[N], const std::u16string& from) {
    if (from.size() >= N) { to[0]=0; return false; }
    std::copy(from.begin(),from.end(),to); to[from.size()]=0; return true;
}
template<size_t N> bool terminated(const char16_t (&s)[N]) { return std::find(s,s+N,u'\0')!=s+N; }
inline bool valid(const Request& r) {
    return r.signature==magic && r.protocol==version && r.operation<=Operation::shutdown &&
        terminated(r.text) && terminated(r.source) && terminated(r.target);
}
}
