// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>


/**
 * Changeset operation types.
 * @since 3.0
 */
typedef NS_ENUM(NSUInteger, IINKChangesetOperationType)
{
  /** Add items operation. */
  ADD       = 0,
  /** Erase items operation. */
  ERASE     = 1,
  /** Transform items operation. */
  TRANSFORM = 2,
  /** Set items type operation. */
  SET_TYPE  = 3
};


/**
 * Represents a changeset operation.
 * @since 3.0
 */
@interface IINKChangesetOperation : NSObject
{

}

/**
 * Create a new `IINKChangesetOperation` instance.
 * @param operationType the operation type.
 * @param strokeIds The list of changed items.
 */
- (nonnull instancetype) init:(IINKChangesetOperationType)operationType strokeIds:(NSArray<NSString *> * _Nonnull)strokeIds;

/** The operation type. */
@property (nonatomic) IINKChangesetOperationType operationType;

/** The list of changed items. */
@property (nonatomic, nonnull) NSArray<NSString *> * strokeIds;

@end
