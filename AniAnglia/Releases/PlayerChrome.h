#pragma once
#import <UIKit/UIKit.h>
// Independent foreground views: UIKit's lazily-created imageView must never end up behind blur.
@interface AniPlayerButton : UIButton
@property(nonatomic, strong) UIVisualEffectView* glass;
@property(nonatomic, strong) UIImageView* glyph;
@property(nonatomic, strong) UILabel* caption;
@property(nonatomic) NSInteger chromeStyle; // 0: capsule, 1: transparent transport, 2: small close circle
@end
@implementation AniPlayerButton
-(instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.backgroundColor=UIColor.clearColor;
        self.glass=[[UIVisualEffectView alloc] initWithEffect:UIAccessibilityIsReduceTransparencyEnabled() ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        self.glass.backgroundColor=UIAccessibilityIsReduceTransparencyEnabled() ? [UIColor colorWithWhite:0.12 alpha:1] : [UIColor colorWithWhite:0.7 alpha:0.08];
        self.glass.userInteractionEnabled=NO; self.glass.clipsToBounds=YES;
        self.glass.layer.borderWidth=0.5; self.glass.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.26].CGColor;
        self.glyph=[UIImageView new]; self.glyph.contentMode=UIViewContentModeScaleAspectFit; self.glyph.tintColor=UIColor.whiteColor;
        self.caption=[UILabel new]; self.caption.textColor=UIColor.whiteColor; self.caption.textAlignment=NSTextAlignmentCenter;
        self.caption.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightRegular]];
        self.caption.adjustsFontForContentSizeCategory=YES; self.caption.numberOfLines=1; self.caption.adjustsFontSizeToFitWidth=YES; self.caption.minimumScaleFactor=0.8;
        self.glyph.userInteractionEnabled=NO; self.caption.userInteractionEnabled=NO;
        [self addSubview:self.glass]; [self addSubview:self.glyph]; [self addSubview:self.caption];
        self.isAccessibilityElement=YES;
    }
    return self;
}
-(void)setTitle:(NSString*)title forState:(UIControlState)state {
    if (state==UIControlStateNormal) { self.caption.text=title; [self setNeedsLayout]; }
}
-(void)setImage:(UIImage*)image forState:(UIControlState)state {
    if (state==UIControlStateNormal) { self.glyph.image=[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]; [self setNeedsLayout]; }
}
-(void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; self.alpha=highlighted ? 0.65 : (self.enabled ? 1 : 0.45); }
-(void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; self.alpha=enabled ? 1 : 0.45; }
-(void)layoutSubviews {
    [super layoutSubviews];
    CGFloat visualHeight=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) ? 42 : 30;
    if (self.chromeStyle==2) visualHeight=32;
    CGFloat diameter=self.chromeStyle==2 ? 32 : self.bounds.size.width;
    self.glass.frame=CGRectMake((self.bounds.size.width-diameter)/2,(self.bounds.size.height-visualHeight)/2,diameter,visualHeight);
    self.glass.layer.cornerRadius=self.chromeStyle==2 ? 16 : visualHeight/2; self.glass.hidden=self.chromeStyle==1;
    BOOL hasText=self.caption.text.length>0,hasImage=self.glyph.image!=nil;
    CGFloat size=self.chromeStyle==1 ? 24 : (self.chromeStyle==2 ? 16 : 14);
    CGFloat textWidth=hasText ? MIN([self.caption sizeThatFits:self.bounds.size].width,MAX(0,self.bounds.size.width-(hasImage ? size+28 : 20))) : 0;
    CGFloat group=textWidth+(hasImage ? size : 0)+(hasText && hasImage ? 6 : 0),start=(self.bounds.size.width-group)/2;
    self.glyph.frame=CGRectMake(start,(self.bounds.size.height-size)/2,size,size); self.glyph.hidden=!hasImage;
    self.caption.frame=CGRectMake(start+(hasImage ? size+6 : 0),0,textWidth,self.bounds.size.height);
    [self sendSubviewToBack:self.glass]; [self bringSubviewToFront:self.glyph]; [self bringSubviewToFront:self.caption];
}
@end
// Draw the rail/thumb ourselves: system slider appearance must not change the reference geometry.
@interface AniPlayerSlider : UIControl
@property(nonatomic) float value;
@property(nonatomic) float minimumValue;
@property(nonatomic) float maximumValue;
@property(nonatomic, strong) UIColor* minimumTrackTintColor;
@property(nonatomic, strong) UIColor* maximumTrackTintColor;
@end
@implementation AniPlayerSlider
-(instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        _maximumValue=1; self.backgroundColor=UIColor.clearColor;
        _minimumTrackTintColor=UIColor.whiteColor; _maximumTrackTintColor=[UIColor colorWithWhite:1 alpha:0.22];
        self.isAccessibilityElement=YES; self.accessibilityTraits=UIAccessibilityTraitAdjustable;
    }
    return self;
}
-(void)setValue:(float)value {
    _value=(value>=self.minimumValue && value<=self.maximumValue) ? value : (value<self.minimumValue ? self.minimumValue : self.maximumValue);
    [self setNeedsDisplay];
}
-(void)drawRect:(CGRect)rect {
    CGFloat fraction=self.maximumValue>self.minimumValue ? (self.value-self.minimumValue)/(self.maximumValue-self.minimumValue) : 0;
    CGFloat width=MAX(0,self.bounds.size.width-9),x=4.5+fraction*width,y=self.bounds.size.height/2;
    [self.maximumTrackTintColor setFill]; [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4.5,y-1.5,width,3) cornerRadius:1.5] fill];
    [self.minimumTrackTintColor setFill]; if (x>4.5) [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4.5,y-1.5,x-4.5,3) cornerRadius:1.5] fill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(x-4.5,y-4.5,9,9)] fill];
}
-(BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event { return CGRectContainsPoint(CGRectInset(self.bounds,0,-6),point); }
-(void)updateTouch:(UITouch*)touch {
    CGFloat width=MAX(1,self.bounds.size.width-9),fraction=MAX(0,MIN(1,([touch locationInView:self].x-4.5)/width));
    self.value=self.minimumValue+fraction*(self.maximumValue-self.minimumValue);
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
-(void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (!self.enabled) return; self.highlighted=YES;
    [self sendActionsForControlEvents:UIControlEventTouchDown]; [self updateTouch:touches.anyObject];
}
-(void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { if (self.enabled && self.highlighted) [self updateTouch:touches.anyObject]; }
-(void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (!self.enabled || !self.highlighted) return; [self updateTouch:touches.anyObject]; self.highlighted=NO;
    [self sendActionsForControlEvents:[self pointInside:[touches.anyObject locationInView:self] withEvent:event] ? UIControlEventTouchUpInside : UIControlEventTouchUpOutside];
}
-(void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { self.highlighted=NO; [self sendActionsForControlEvents:UIControlEventTouchCancel]; }
-(void)accessibilityIncrement { if (self.enabled) { self.value=MIN(self.maximumValue,self.value+0.01); [self sendActionsForControlEvents:UIControlEventValueChanged]; } }
-(void)accessibilityDecrement { if (self.enabled) { self.value=MAX(self.minimumValue,self.value-0.01); [self sendActionsForControlEvents:UIControlEventValueChanged]; } }
@end
@interface AniPlayerOverlay : UIView
@end
@implementation AniPlayerOverlay
-(UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* hit=[super hitTest:point withEvent:event]; return hit==self ? nil : hit;
}
@end
@interface AniPlayerShade : UIView
@end
@implementation AniPlayerShade
-(void)drawRect:(CGRect)rect {
    CGContextRef context=UIGraphicsGetCurrentContext();
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGFloat components[]={0,0,0,0, 0,0,0,0.48}; CGFloat locations[]={0,1};
    CGGradientRef gradient=CGGradientCreateWithColorComponents(space,components,locations,2);
    CGContextDrawLinearGradient(context,gradient,CGPointMake(0,0),CGPointMake(0,self.bounds.size.height),0);
    CGGradientRelease(gradient); CGColorSpaceRelease(space);
}
@end
// Nonempty fallback for essential icons, even when a system symbol is unavailable.
static inline UIImage* AniPlayerIcon(NSString* name) {
    UIImageSymbolConfiguration* config=[UIImageSymbolConfiguration configurationWithPointSize:16 weight:[name isEqual:@"xmark"] ? UIImageSymbolWeightBold : UIImageSymbolWeightSemibold];
    UIImage* image=[UIImage systemImageNamed:name withConfiguration:config]; if (image) return image;
    UIGraphicsImageRenderer* renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(24,24)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        CGContextRef c=context.CGContext; CGContextSetStrokeColorWithColor(c,UIColor.whiteColor.CGColor); CGContextSetFillColorWithColor(c,UIColor.whiteColor.CGColor); CGContextSetLineWidth(c,2); CGContextSetLineCap(c,kCGLineCapRound);
        if ([name isEqual:@"xmark"]) {
            CGContextMoveToPoint(c,6,6); CGContextAddLineToPoint(c,18,18); CGContextMoveToPoint(c,18,6); CGContextAddLineToPoint(c,6,18); CGContextStrokePath(c);
        } else if ([name isEqual:@"pause.fill"]) {
            CGContextFillRect(c,CGRectMake(5,3,5,18)); CGContextFillRect(c,CGRectMake(14,3,5,18));
        } else if ([name isEqual:@"play.fill"] || [name isEqual:@"forward.end.fill"]) {
            CGContextMoveToPoint(c,5,3); CGContextAddLineToPoint(c,19,12); CGContextAddLineToPoint(c,5,21); CGContextClosePath(c); CGContextFillPath(c);
            if ([name isEqual:@"forward.end.fill"]) CGContextFillRect(c,CGRectMake(20,3,2,18));
        } else if ([name isEqual:@"gobackward.10"] || [name isEqual:@"goforward.10"]) {
            CGContextAddArc(c,12,13,9,-1.3,4.3,0); CGContextStrokePath(c);
            CGContextMoveToPoint(c,5,2); CGContextAddLineToPoint(c,5,7); CGContextAddLineToPoint(c,10,7); CGContextStrokePath(c);
            [@"10" drawInRect:CGRectMake(6,8,14,12) withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:10],NSForegroundColorAttributeName:UIColor.whiteColor}];
        } else if ([name isEqual:@"ellipsis"]) {
            for (int i=0;i<3;++i) CGContextFillEllipseInRect(c,CGRectMake(3+i*8,10,3,3));
        } else {
            for (int i=0;i<3;++i) { CGContextMoveToPoint(c,3,6+i*6); CGContextAddLineToPoint(c,21,6+i*6); }
            CGContextStrokePath(c);
        }
    }];
}
