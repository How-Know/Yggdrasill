// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>

/**
 * Represents a MIME type.
 * @see http://www.iana.org/assignments/media-types/index.html
 */
typedef NS_ENUM(NSUInteger, IINKMimeType)
{
  /** Plain text (text/plain). */
  IINKMimeTypeText = 1 << 0,
  /** HyperText Markup Language (text/html) */
  IINKMimeTypeHTML = 1 << 1,
  /** Mathematical Markup Language (application/mathml+xml). */
  IINKMimeTypeMathML = 1 << 2,
  /** LaTeX (application/x-latex). */
  IINKMimeTypeLaTeX = 1 << 3,
  /** Graph Markup Language (application/graphml+xml). */
  IINKMimeTypeGraphML = 1 << 4,
  /** Music Extensible Markup Language (application/vnd.recordare.musicxml+xml). */
  IINKMimeTypeMusicXML = 1 << 5,
  /** Scalable Vector Graphics (image/svg+xml). */
  IINKMimeTypeSVG = 1 << 6,
  /** Json Interactive Ink eXchange format (application/vnd.myscript.jiix). */
  IINKMimeTypeJIIX = 1 << 7,
  /** JPEG Image (image/jpeg). */
  IINKMimeTypeJPEG = 1 << 8,
  /** PNG Image (image/png). */
  IINKMimeTypePNG = 1 << 9,
  /** GIF Image (image/gif). */
  IINKMimeTypeGIF = 1 << 10,
  /** Portable Document Format (application/pdf). */
  IINKMimeTypePDF = 1 << 11,
  /** Open XML word processing document (application/vnd.openxmlformats-officedocument.wordprocessingml.document). */
  IINKMimeTypeDOCX = 1 << 12,
  /** Open XML presentation (application/vnd.openxmlformats-officedocument.presentationml.presentation). */
  IINKMimeTypePPTX = 1 << 13,
  /** Microsoft Office Clipboard format (Art::GVML ClipFormat). @since 1.1 */
  IINKMimeTypeOfficeClipboard = 1 << 14
};


/**
 * Wrapper object for an `IINKMimeType` value.
 */
@interface IINKMimeTypeValue : NSObject
{

}

@property (nonatomic) IINKMimeType value;

/**
 * Create a new `IINKMimeTypeValue` instance.
 * @param value the mime type value.
 */
- (nullable instancetype)initWithValue:(IINKMimeType)value;

/**
 * Builds a new `IINKMimeTypeValue` instance.
 * @param value the mime type value.
 */
+ (nonnull IINKMimeTypeValue *)valueWithMimeType:(IINKMimeType)value;


//==============================================================================
#pragma mark - Utilities
//==============================================================================

/**
 * Returns a descriptive name in English.
 *
 * @param mimeType the MIME type.
 *
 * @return the descriptive name
 */
+ (NSString * _Nonnull)IINKMimeTypeGetName:(IINKMimeType)mimeType;

/**
 * Returns the name of the media type, in the form "type/subtype".
 *
 * @param mimeType the MIME type.
 *
 * @return the name of the media type.
 */
+ (NSString * _Nonnull)IINKMimeTypeGetTypeName:(IINKMimeType)mimeType;

/**
 * Returns a comma separated list of file extensions.
 *
 * @param mimeType the MIME type.
 *
 * @return the file extensions, or <code>null</code>
 */
+ (NSString * _Nonnull)IINKMimeTypeGetFileExtensions:(IINKMimeType)mimeType;

/**
 * Tells whether the specified MIME type is textual.
 *
 * @param mimeType the MIME type.
 *
 * @return `true` if the MIME type is textual, `false` otherwise.
 */
+ (BOOL)IINKMimeTypeIsTextual:(IINKMimeType)mimeType;

/**
 * Tells whether the specified MIME type is an image MIME type.
 *
 * @param mimeType the MIME type.
 *
 * @return `true` if the MIME type is an image MIME type, `false` otherwise.
 */
+ (BOOL)IINKMimeTypeIsImage:(IINKMimeType)mimeType;

@end
