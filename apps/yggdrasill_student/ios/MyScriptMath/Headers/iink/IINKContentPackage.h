// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>


@class IINKContentPart;
@class IINKParameterSet;

/**
 * A package stores the user content as a sorted collection of parts.
 */
@interface IINKContentPackage : NSObject
{

}

//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * This package's metadata as a parameter set.
 */
@property (nonatomic, nullable) IINKParameterSet *metadata;

/**
 * The path of this package.
 *
 * @since 2.0
 */
@property (nonatomic, readonly, nonnull) NSString *path;


//==============================================================================
#pragma mark - Save
//==============================================================================

/**
 * Saves all ongoing modifications made to this package.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when an I/O operation fails.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)saveWithError:(NSError * _Nullable * _Nullable)error;

/**
 * Saves all ongoing modifications made to this package, to a temporary folder.
 * This operation is faster than `save()`.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when an I/O operation fails.
 * @return `YES` on success, otherwise `NO`.
 *
 * @note by default temporary folder is located in the same directory as this
 *   package, and named by appending `-files` to this package's name.
 *
 * @note temporary folder location can be set via the
 *   `content-package.temp-folder` configuration property.
 */
- (BOOL)saveToTempWithError:(NSError * _Nullable * _Nullable)error;

/**
 * Saves of all ongoing modifications made to this package, to a new file.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when an I/O operation fails.
 * @return `YES` on success, otherwise `NO`.
 *
 * @param fileName the new file name.
 */
- (BOOL)saveAs:(nonnull NSString *)fileName
         error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(save(as:));


//==============================================================================
#pragma mark - Part Management
//==============================================================================

/**
 * Returns the number of parts in this package.
 */
- (NSInteger)partCount;

/**
 * Returns the part at the specified index.
 *
 * @param index the index of the requested part.
 * @param error the recipient for the error description object
 *   * IINKErrorOutOfRange when `index` is out of range.
 * @return the requested part on success, otherwise `nil`.
 */
- (nullable IINKContentPart *)getPartAt:(NSInteger)index
                                  error:(NSError * _Nullable * _Nullable)error
                              NS_SWIFT_NAME(part(at:));

/**
 * Returns the specified part.
 *
 * @param identifier the identifier of the requested part.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when no part is associated with identifier `id`.
 * @return the part on success, otherwise `nil`..
 */
- (nullable IINKContentPart *)getPart:(nonnull NSString *)identifier
                                error:(NSError * _Nullable * _Nullable)error
                              NS_SWIFT_NAME(part(with:));

/**
 * Returns the index of a given part.
 *
 * @param part the part.
 * @return the index of the part if found, otherwise `-1`.
 */
- (NSInteger)indexOfPart:(nonnull IINKContentPart *)part
             NS_SWIFT_NAME(index(of:));

/**
 * Returns the index of a given part.
 *
 * @param part the part.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when part does not belong to this package.
 * @return the index of the part on success, otherwise `-1`.
 */
- (NSInteger)indexOfPart:(nonnull IINKContentPart *)part
                   error:(NSError * _Nullable * _Nullable)error DEPRECATED_MSG_ATTRIBUTE("Use indexOfPart: instead");

/**
 * Appends a new part to this package.
 *
 * @param type the type of part.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `type` is not a valid ContentPart type.
 * @return the newly created part on success, otherwise `nil`.
 */
- (nullable IINKContentPart *)createPart:(nonnull NSString *)type
                                   error:(NSError * _Nullable * _Nullable)error
                              NS_SWIFT_NAME(createPart(with:));

/**
 * Appends a new fixed-size part to this package.
 *
 * @param type the type of part.
 * @param size the width and height of part (document coordinates in mm).
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `type` is not a `Raw Content` ContentPart type.
 *   * IINKErrorInvalidArgument when `size` `width` or `height` are not a number or `< 1.0`.
 * @return the newly created part on success, otherwise `nil`.
 *
 * @since 4.1
 */
- (nullable IINKContentPart *)createPart:(nonnull NSString *)type
                               fixedSize:(CGSize)size
                                   error:(NSError * _Nullable * _Nullable)error
           NS_SWIFT_NAME(createPart(with:fixedSize:));

/**
 * Removes the specified part.
 *
 * @param part the part to remove.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when part does not belong to this package.
 * @return `YES` on success, otherwise `NO`.
 *
 * @since 1.2
 */
- (BOOL)removePart:(nonnull IINKContentPart *)part
             error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(removePart(_:));

/**
 * Moves the given part to another index.
 *
 * @param fromIndex the current index of the requested part.
 * @param toIndex the new index of the part.
 * @param error the recipient for the error description object
 *   * IINKErrorOutOfRange when `fromIndex` is out of range.
 *   * IINKErrorOutOfRange when `toIndex` is out of range.
 * @return `YES` on success, otherwise `NO`.
 *
 * @since 2.1.1
 */
- (BOOL)movePart:(NSInteger)fromIndex
         toIndex:(NSInteger)toIndex
           error:(NSError * _Nullable * _Nullable)error
          NS_SWIFT_NAME(movePart(fromIndex:toIndex:));

/**
 * Adds an existing part to this package.
 *
 * @note Part modifications that have not been saved (to temporary directory
 *   or to an actual package file) will not be imported.
 *
 * @note The part can be an existing part from this package or from another
 *   open package.
 *
 * @param part the part to clone into this package.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `part` is not a valid ContentPart.
 * @return the newly created part on success, otherwise `nil`.
 *
 * @since 1.2
 */
- (nullable IINKContentPart *)clonePart:(nonnull IINKContentPart *)part
                                  error:(NSError * _Nullable * _Nullable)error
                              NS_SWIFT_NAME(clonePart(_:));

//==============================================================================
#pragma mark - Objects
//==============================================================================

/**
 * Extracts an object from this package to a given path.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when no object named `url` exists.
 *   * IINKErrorRuntime when an I/O operation fails.
 * @return `YES` on success, otherwise `NO`.
 *
 * @param url URL of the object.
 * @param fileName destination file.
 */
- (BOOL)extractObject:(nonnull NSString *)url
               toFile:(nonnull NSString *)fileName
                error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(extractObject(with:toFile:));

@end
