#pragma once
#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <string>
#include <vector>
namespace discovery {
struct Candidate {
    long long id = 0;
    std::vector<std::string> genres;
    double rating = 0;
    bool seen = false, dropped = false, favorite = false, watching = false;
};
using Taste = std::map<std::string, int>;
inline void learn(Taste& taste, const std::vector<std::string>& genres, int weight) {
    std::set<std::string> distinct(genres.begin(), genres.end());
    for (const auto& genre : distinct) if (!genre.empty()) taste[genre] = std::clamp(taste[genre] + weight, -100, 100);
}
inline double score(const Candidate& item, const Taste& taste) {
    if (item.id <= 0 || item.seen || item.dropped || item.favorite || item.watching ||
        !std::isfinite(item.rating) || item.rating < 0 || item.rating > 5) return -1;
    double affinity = 0;
    std::set<std::string> distinct(item.genres.begin(), item.genres.end());
    for (const auto& genre : distinct) {
        auto found = taste.find(genre); if (found != taste.end()) affinity += found->second;
    }
    // A bounded mean allows negative preferences without treating them as invalid items.
    return 1000.0 + affinity * 10 / std::max<std::size_t>(1, distinct.size()) + item.rating;
}
inline std::vector<long long> rank(const std::vector<Candidate>& items, const Taste& taste, std::size_t limit = 20) {
    std::vector<std::pair<double, long long>> scored;
    std::set<long long> excluded;
    for (const auto& item : items) if (item.seen || item.dropped || item.favorite || item.watching) excluded.insert(item.id);
    std::map<long long, double> best;
    for (const auto& item : items) {
        double value = score(item, taste);
        if (value >= 0 && !excluded.contains(item.id)) {
            auto found = best.find(item.id);
            if (found == best.end() || value > found->second) best[item.id] = value;
        }
    }
    for (const auto& [id, value] : best) scored.emplace_back(value, id);
    std::sort(scored.begin(), scored.end(), [](const auto& a, const auto& b) {
        return a.first != b.first ? a.first > b.first : a.second < b.second;
    });
    std::vector<long long> result;
    for (const auto& [value, id] : scored) { (void)value; if (result.size() >= limit) break; result.push_back(id); }
    return result;
}
inline bool validYearRange(int from, int to, int currentYear) {
    return currentYear >= 1900 && (!from || (from >= 1900 && from <= currentYear + 5)) &&
        (!to || (to >= 1900 && to <= currentYear + 5)) && (!from || !to || from <= to);
}
}
