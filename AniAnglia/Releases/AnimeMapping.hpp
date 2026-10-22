#pragma once
#include <algorithm>
#include <string>
#include <vector>

namespace playback {
// Titles are Unicode-normalized by Foundation before crossing this boundary.
struct AnimeIdentity {
    long mal = 0;
    std::vector<std::string> titles;
    int year = 0, episodes = 0, category = 0;
    bool ongoing = false;
};
inline bool matchingAnime(const AnimeIdentity& source, const AnimeIdentity& candidate) {
    if (candidate.mal <= 0 || candidate.mal > 1000000000 || candidate.category <= 0 || candidate.category > 3) return false;
    if (source.category && source.category != candidate.category) return false;
    if (!source.category && (source.year <= 0 || source.episodes <= 0)) return false;
    if (source.year <= 0 && source.episodes <= 0) return false;
    if (source.year > 0 && source.year != candidate.year) return false;
    if (source.episodes > 0 && candidate.episodes > 0 && source.episodes != candidate.episodes) return false;
    // An ongoing season can have a null MAL episode count. Exact title + year + format still required.
    if (candidate.episodes <= 0 && (!candidate.ongoing || source.year <= 0 || source.category <= 0 || candidate.year <= 0)) return false;
    for (const auto& title : source.titles) {
        if (title.size() >= 3 && std::find(candidate.titles.begin(), candidate.titles.end(), title) != candidate.titles.end()) return true;
    }
    return false;
}
// Refuse ambiguity, even if a search result happens to rank first.
inline long uniqueAnime(const AnimeIdentity& source, const std::vector<AnimeIdentity>& candidates, bool complete) {
    if (!complete) return 0;
    long selected = 0;
    for (const auto& candidate : candidates) {
        if (!matchingAnime(source, candidate)) continue;
        if (selected && selected != candidate.mal) return 0;
        selected = candidate.mal;
    }
    return selected;
}
// Verified MAL catalogue entry, not episode timing. Timings still come from AniSkip per video.
// Source: https://myanimelist.net/anime/54595/Kage_no_Jitsuryokusha_ni_Naritakute_2nd_Season
inline long verifiedAnime(const AnimeIdentity& source) {
    const AnimeIdentity shadow2{54595, {
        "kagenojitsuryokushaninaritakute2ndseason", "kagenojitsuryokushaninaritakute2",
        "theeminenceinshadowseason2", "shadowgarden2ndseason",
        "восхождениевтени2", "восхождениевтени2сезон", "восхождениевтенисезон2",
        "восхождениевтени2йсезон", "восхождениевтенитв2", "陰の実力者になりたくて2ndseason"
    }, 2023, 12, 1};
    return matchingAnime(source, shadow2) ? shadow2.mal : 0;
}
// A source position is not necessarily a season episode number (including zero-based sources).
// Named numbers are preferred. Unknown labels/specials never silently become normal episodes.
inline long mappedEpisode(const std::vector<long>& positions, const std::vector<long>& numbers,
                          long current, long total) {
    if (positions.size() != numbers.size() || total <= 0) return 0;
    auto found = std::find(positions.begin(), positions.end(), current);
    if (found == positions.end() || std::count(positions.begin(), positions.end(), current) != 1) return 0;
    const auto index = static_cast<std::size_t>(found - positions.begin());
    long number = numbers[index];
    if (number > 0) {
        return number <= total && std::count(numbers.begin(), numbers.end(), number) == 1 ? number : 0;
    }
    // Only genuinely absent labels (0), NOT unrecognized nonempty labels (-1), permit inference.
    if (std::any_of(numbers.begin(), numbers.end(), [](long n) { return n != 0; })) return 0;
    auto sorted = positions;
    std::sort(sorted.begin(), sorted.end());
    if (sorted.empty() || sorted.back() > total) return 0;
    for (std::size_t i = 0; i < sorted.size(); ++i) if (sorted[i] != static_cast<long>(i + 1)) return 0;
    return current;
}
}
