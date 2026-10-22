#pragma once
#include <algorithm>
namespace playback {
struct ChromeRect { double x=0,y=0,w=0,h=0; };
struct ChromeLayout {
    ChromeRect close,status,panel,skip,next,slider,back,play,forward,speed,more,time;
    bool horizontal=false,shortVideo=false;
};
// Shared UIKit/portable geometry. One centred panel, 44pt minimum hit targets.
inline ChromeLayout chromeLayout(double x,double y,double width,double height,bool hasSkip,bool hasNext,bool largeText=false) {
    ChromeLayout c;
    double panelWidth=std::max(0.0,std::min(width-16,640.0));
    double left=x+(width-panelWidth)/2+12,right=left+panelWidth-24,available=right-left;
    double bottom=y+height-(height<260 ? 4 : 8);
    c.horizontal=available>=448 && !largeText; c.shortVideo=height<260;
    c.close={x+12,y+4,44,44}; // UIKit anchors close to the screen safe area, outside portrait letterboxing.
    c.status={};
    double row=bottom-(c.shortVideo ? 44 : 52);
    c.back={left,row,44,44}; c.play={left+44,row,44,44}; c.forward={left+88,row,44,44};
    c.more={right-44,row,44,44}; c.speed={right-108,row,64,44};
    c.time=c.horizontal ? ChromeRect{left+(available-120)/2,row,120,44} : ChromeRect{left,bottom-(c.shortVideo ? 108 : 120),available,c.shortVideo ? 24.0 : 28.0};
    c.slider={left,bottom-(c.shortVideo ? 80 : 88),available,c.shortVideo ? 28.0 : 32.0};
    double actionsBottom=c.horizontal ? bottom-88 : bottom-(c.shortVideo ? 112 : 124);
    double skipWidth=c.shortVideo ? 140 : (largeText ? 200 : 176),nextWidth=c.shortVideo ? 88 : (largeText ? 104 : 88),gap=4;
    double actionHeight=0;
    if (hasSkip || hasNext) {
        bool sideBySide=!hasSkip || !hasNext || available>=skipWidth+nextWidth+gap;
        if (sideBySide) {
            double total=(hasSkip?skipWidth:0)+(hasNext?nextWidth:0)+(hasSkip&&hasNext?gap:0);
            double cursor=left+(available-total)/2;
            if (hasSkip) { c.skip={cursor,actionsBottom-44,skipWidth,44};cursor+=skipWidth+gap; }
            if (hasNext) c.next={cursor,actionsBottom-44,nextWidth,44};
            actionHeight=44;
        } else {
            c.next={left+(available-nextWidth)/2,actionsBottom-44,nextWidth,44};
            c.skip={left+(available-skipWidth)/2,actionsBottom-88,skipWidth,44}; actionHeight=88;
        }
    }
    double top=(hasSkip||hasNext) ? actionsBottom-actionHeight-8 : (c.horizontal ? bottom-88 : bottom-120)-8;
    top=std::max(y,top); c.panel={left-12,top,panelWidth,bottom-top};
    return c;
}
}
