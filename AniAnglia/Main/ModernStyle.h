#pragma once
#import <UIKit/UIKit.h>
// Public iOS 14 APIs only. A material style, not a dependency on an unreleased iOS UI API.
static inline void AniStyleNavigation(UINavigationController* navigation) {
    UINavigationBarAppearance* appearance = [UINavigationBarAppearance new];
    [appearance configureWithDefaultBackground];
    appearance.backgroundEffect = UIAccessibilityIsReduceTransparencyEnabled() ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    if (UIAccessibilityIsReduceTransparencyEnabled()) appearance.backgroundColor = UIColor.systemBackgroundColor;
    appearance.shadowColor = UIColor.clearColor;
    navigation.navigationBar.standardAppearance = appearance;
    navigation.navigationBar.scrollEdgeAppearance = appearance;
    navigation.navigationBar.compactAppearance = appearance;
    navigation.navigationBar.tintColor = UIColor.systemBlueColor;
}
static inline void AniStyleButton(UIButton* button, BOOL prominent) {
    button.layer.cornerRadius = 16;
    button.backgroundColor = prominent ? UIColor.systemBlueColor : UIColor.secondarySystemGroupedBackgroundColor;
    [button setTitleColor:prominent ? UIColor.whiteColor : UIColor.labelColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.numberOfLines = 2;
    button.contentEdgeInsets = UIEdgeInsetsMake(12, 14, 12, 14);
    button.accessibilityTraits |= UIAccessibilityTraitButton;
}
