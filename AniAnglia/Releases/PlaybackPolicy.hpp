#pragma once
#include <algorithm>
#include <cctype>
#include <cmath>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace playback {
inline int qualityNumber(std::string_view label) {
    int value = 0;
    for (unsigned char c : label) {
        if (!std::isdigit(c)) break;
        value = std::min(100000, value * 10 + c - '0');
    }
    return value;
}
inline std::string chooseQuality(const std::unordered_map<std::string, std::string>& qualities, std::string_view preferred) {
    auto exact = qualities.find(std::string(preferred));
    if (exact != qualities.end() && !exact->second.empty()) return exact->second;
    const int requested = qualityNumber(preferred);
    std::string result;
    int bestRank = -1, bestValue = -1;
    for (const auto& [label, url] : qualities) {
        if (url.empty()) continue;
        int value = qualityNumber(label);
        // Same resolution (720p), then highest below preference, then lowest above.
        int rank = requested > 0 ? (value == requested ? 4 : (value > 0 && value < requested ? 3 : (value > 0 ? 2 : 1))) : 1;
        int score = rank == 2 ? -value : value;
        if (rank > bestRank || (rank == bestRank && (score > bestValue || (score == bestValue && url < result)))) {
            bestRank = rank; bestValue = score; result = url;
        }
    }
    return result;
}
inline long nextPosition(const std::vector<long>& positions, long current) {
    long result = -1;
    for (long position : positions) if (position > current && (result < 0 || position < result)) result = position;
    return result;
}
inline double openingTarget(double seconds, double duration, double begin, double length) {
    if (!std::isfinite(seconds) || !std::isfinite(duration) || !std::isfinite(begin) || !std::isfinite(length)) return -1;
    if (seconds < 0 || begin < 0 || length <= 0 || duration <= 0) return -1;
    double target = begin + length;
    return seconds >= begin && seconds < target && target < duration ? target : -1;
}
// A skip interval is usable only for its confirmed, matching-duration video.
inline bool validOpeningInterval(double begin, double end, double duration) {
    return std::isfinite(begin) && std::isfinite(end) && std::isfinite(duration) &&
        begin >= 0 && end - begin >= 1 && end < duration && duration > 0;
}
inline double confirmedOpeningTarget(double seconds, double duration, double begin, double end, double referenceDuration, bool confirmed) {
    if (!confirmed || !std::isfinite(referenceDuration) || std::abs(referenceDuration - duration) > 1.0 ||
        !validOpeningInterval(begin, end, duration)) return -1;
    return openingTarget(seconds, duration, begin, end - begin);
}
// Strict seconds / mm:ss / hh:mm:ss parser. Never silently turn invalid input into 0.
inline double parseTimestamp(std::string_view text) {
    while (!text.empty() && std::isspace(static_cast<unsigned char>(text.front()))) text.remove_prefix(1);
    while (!text.empty() && std::isspace(static_cast<unsigned char>(text.back()))) text.remove_suffix(1);
    if (text.empty()) return -1;
    double total = 0;
    int parts = 0;
    while (!text.empty()) {
        size_t colon = text.find(':');
        auto part = text.substr(0, colon);
        if (part.empty() || ++parts > 3) return -1;
        double value = 0, fraction = 0.1;
        bool decimal = false, digit = false, fractionalDigit = false;
        for (unsigned char c : part) {
            if (c == '.' || c == ',') { if (decimal || colon != std::string_view::npos || !digit) return -1; decimal = true; continue; }
            if (c < '0' || c > '9') return -1;
            digit = true;
            if (decimal) { value += (c - '0') * fraction; fraction *= 0.1; fractionalDigit = true; }
            else value = value * 10 + c - '0';
            if (value > 86400) return -1;
        }
        if (!digit || (decimal && !fractionalDigit) || (parts > 1 && value >= 60)) return -1;
        total = total * 60 + value;
        if (total > 86400) return -1;
        if (colon == std::string_view::npos) return total;
        text.remove_prefix(colon + 1);
        if (text.empty()) return -1;
    }
    return -1;
}
inline bool shouldSkipEnding(double seconds, double duration, double length, bool hasNext) {
    return hasNext && std::isfinite(seconds) && std::isfinite(duration) && std::isfinite(length) && length > 0 &&
        duration > length + 30 && seconds >= duration - length && seconds < duration;
}
}
