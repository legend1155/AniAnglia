#pragma once
#include <algorithm>
#include <cmath>
#include <vector>
namespace discovery {
// Only continuous playback earns credit. Resume, seeks, stalled and paused time do not.
class WatchSampler {
    double previous_ = -1, wall_ = -1, start_ = -1, rate_ = 0;
public:
    void reset() { previous_ = wall_ = start_ = -1; rate_ = 0; }
    std::vector<int> sample(double position, double wall, double rate, double duration, bool active) {
        std::vector<int> result;
        if (!active || !std::isfinite(position) || !std::isfinite(wall) || !std::isfinite(rate) ||
            !std::isfinite(duration) || duration <= 0 || duration > 18000 || position < 0 || position > duration || rate <= 0 || rate > 4) {
            reset(); return result;
        }
        double delta = position - previous_, elapsed = wall - wall_;
        bool continuous = previous_ >= 0 && elapsed > 0 && elapsed <= 2 && delta > 0 &&
            std::abs(delta - elapsed * rate_) <= std::max(0.15, elapsed * rate_ * 0.35) && rate == rate_;
        if (continuous) {
            if (start_ < 0) start_ = previous_;
            // Whole seconds only, with a continuous start no later than that second.
            int first = std::max((int)std::ceil(start_), (int)std::floor(previous_));
            for (int second = first; second < (int)std::floor(position); ++second) result.push_back(second);
        } else start_ = position;
        previous_ = position; wall_ = wall; rate_ = rate;
        return result;
    }
};
inline int watchInterest(double watched, double duration) {
    if (!std::isfinite(watched) || !std::isfinite(duration) || watched < 0 || duration < 60 || watched > duration + 1) return 0;
    double ratio = watched / duration;
    // A brief exit is neutral. Minutes AND coverage are required, including for movies.
    if (ratio >= 0.8 && watched >= std::min(600.0, duration * 0.8)) return 3;
    if (ratio >= 0.5 && watched >= std::min(300.0, duration * 0.5)) return 2;
    if (ratio >= 0.25 && watched >= std::min(180.0, duration * 0.25)) return 1;
    return 0;
}
inline bool controlsShouldHide(bool hidden, bool playing, bool interacting, bool accessible, double now, double deadline) {
    return !hidden && playing && !interacting && !accessible && std::isfinite(now) && now >= deadline;
}
}
