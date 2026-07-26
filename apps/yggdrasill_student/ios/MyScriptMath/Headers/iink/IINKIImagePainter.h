// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/graphics/IINKICanvas.h>


/**
 * The ImagePainter converts rendering data into images in view e.g. for
 * integration into .docx exports.
 */
@protocol IINKIImagePainter <NSObject>

@required

/**
 * Invoked before starting to draw an image.
 * This call is meant to enable preparation of the image destination in memory
 * (e.g. memory allocation).
 *
 * @param size the image size.
 * @param dpi the resolution of the image in dots per inch.
 */
- (void)prepareImage:(CGSize)size dpi:(float)dpi;

/**
 * Invoked once image drawing is over.
 * Requests saving the image to disk.
 *
 * @param path the image destination.
 */
- (void)saveImage:(nonnull NSString *)path;


/**
 * Creates a canvas to draw the image.
 *
 * @return a canvas to draw the image.
 *
 * @since 2.0
 */
- (nonnull id<IINKICanvas>)createCanvas;

@end
