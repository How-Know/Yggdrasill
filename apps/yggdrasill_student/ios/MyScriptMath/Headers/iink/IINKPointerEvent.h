// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/**
 * Describes the types of pointer that can be used for input.
 */
typedef NS_ENUM(NSUInteger, IINKPointerType)
{
  /** The pointer is a pen. */
  IINKPointerTypePen     = 0,
  /** The pointer is a touch point. */
  IINKPointerTypeTouch   = 1,
  /** The pointer is an eraser. */
  IINKPointerTypeEraser  = 2,
  /** The pointer is a mouse. */
  IINKPointerTypeMouse   = 3,
  /** The pointer is Custom. */
  IINKPointerTypeCustom1 = 4,
  /** The pointer is Custom. */
  IINKPointerTypeCustom2 = 5,
  /** The pointer is Custom. */
  IINKPointerTypeCustom3 = 6,
  /** The pointer is Custom. */
  IINKPointerTypeCustom4 = 7,
  /** The pointer is Custom. */
  IINKPointerTypeCustom5 = 8
};

/**
 * Describes the types of pointer event that can be provided to the editor.
 */
typedef NS_ENUM(NSUInteger, IINKPointerEventType)
{
  /** A pointer down event. */
  IINKPointerEventTypeDown,
  /** A pointer move event. */
  IINKPointerEventTypeMove,
  /** A pointer up event. */
  IINKPointerEventTypeUp,
  /** A pointer cancel event. */
  IINKPointerEventTypeCancel
};

/**
 * Represents a pointer event.
 */
typedef struct _IINKPointerEvent
{
  /** The event type. */
  IINKPointerEventType eventType;
  /** The event x coordinate. */
  float x;
  /** The event y coordinate. */
  float y;
  /** The event timestamp in ms since Unix EPOCH, or -1. */
  int64_t t;
  /** The event normalized pressure, in [0,1]. */
  float f;
  /** The event tilt in radians. 0 is perpendicular, Pi/2 if flat on screen. */
  float tilt;
  /** The event orientation in radians. 0 is pointing up, -Pi/2 is left, Pi/2 is right, +/-Pi is down. */
  float orientation;
  /** The type of input pointer. */
  IINKPointerType pointerType;
  /** The id of the pointer. */
  int pointerId;
} IINKPointerEvent;

CG_INLINE IINKPointerEvent
IINKPointerEventMake(IINKPointerEventType eventType,
                     CGPoint point, int64_t t, float f,
                     IINKPointerType pointerType, int pointerId)
{
  IINKPointerEvent e;
  e.eventType = eventType;
  e.x = (float)point.x;
  e.y = (float)point.y;
  e.t = t;
  e.f = f;
  e.tilt = -1.f;
  e.orientation = -10.f;
  e.pointerType = pointerType;
  e.pointerId = pointerId;
  return e;
}

CG_INLINE IINKPointerEvent
IINKPointerEventMakeWithTilt(IINKPointerEventType eventType,
                             CGPoint point, int64_t t, float f, float tilt, float orientation,
                             IINKPointerType pointerType, int pointerId)
{
  IINKPointerEvent e;
  e.eventType = eventType;
  e.x = (float)point.x;
  e.y = (float)point.y;
  e.t = t;
  e.f = f;
  e.tilt = tilt;
  e.orientation = orientation;
  e.pointerType = pointerType;
  e.pointerId = pointerId;
  return e;
}

CG_INLINE IINKPointerEvent
IINKPointerEventMakeDown(CGPoint point, int64_t t, float f,
                         IINKPointerType pointerType, int pointerId)
{
  return IINKPointerEventMake(IINKPointerEventTypeDown, point, t, f, pointerType, pointerId);
}

CG_INLINE IINKPointerEvent
IINKPointerEventMakeDownWithTilt(CGPoint point, int64_t t, float f, float tilt, float orientation,
                                 IINKPointerType pointerType, int pointerId)
{
  return IINKPointerEventMakeWithTilt(IINKPointerEventTypeDown, point, t, f, tilt, orientation, pointerType, pointerId);
}

CG_INLINE IINKPointerEvent
IINKPointerEventMakeMove(CGPoint point, int64_t t, float f,
                         IINKPointerType pointerType, int pointerId)
{
  return IINKPointerEventMake(IINKPointerEventTypeMove, point, t, f, pointerType, pointerId);
}

CG_INLINE IINKPointerEvent
IINKPointerEventMakeMoveWithTilt(CGPoint point, int64_t t, float f, float tilt, float orientation,
                                 IINKPointerType pointerType, int pointerId)
{
  return IINKPointerEventMakeWithTilt(IINKPointerEventTypeMove, point, t, f, tilt, orientation, pointerType, pointerId);
}

CG_INLINE IINKPointerEvent
IINKPointerEventMakeUp(CGPoint point, int64_t t, float f,
                       IINKPointerType pointerType, int pointerId)
{
  return IINKPointerEventMake(IINKPointerEventTypeUp, point, t, f, pointerType, pointerId);
}

CG_INLINE IINKPointerEvent
IINKPointerEventMakeUpWithTilt(CGPoint point, int64_t t, float f, float tilt, float orientation,
                               IINKPointerType pointerType, int pointerId)
{
  return IINKPointerEventMakeWithTilt(IINKPointerEventTypeUp, point, t, f, tilt, orientation, pointerType, pointerId);
}

CG_INLINE IINKPointerEvent
IINKPointerEventMakeCancel(int pointerId)
{
  return IINKPointerEventMake(IINKPointerEventTypeCancel, CGPointMake(0, 0), -1, 0, (IINKPointerType)0, pointerId);
}


/**
 * Wrapper object for an `IINKPointerEvent` value.
 */
@interface IINKPointerEventValue : NSObject
{

}

@property (nonatomic) IINKPointerEvent value;

/**
 * Create a new `IINKPointerEventValue` instance.
 * @param value the pointer event value.
 */
- (nullable instancetype)initWithValue:(IINKPointerEvent)value;

/**
 * Builds a new `IINKPointerEventValue` instance.
 * @param value the pointer event value.
 */
+ (nonnull IINKPointerEventValue *)valueWithPointerEvent:(IINKPointerEvent)value;

@end
