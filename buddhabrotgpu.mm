/*  Buddhabrot
    https://github.com/Michaelangel007/buddhabrot
    http://en.wikipedia.org/wiki/User_talk:Michael.Pohoreski/Buddhabrot.cpp

    Initially optimized and cleaned up version by Michael Pohoreski
    Based on the original version by Evercat
    Hacked solution for utilizing Apple GPU by Nicolas Ramsrud

   Released under the GNU Free Documentation License
   or the GNU Public License, whichever you prefer.
*/

#if _WIN32
    #define _CRT_SECURE_NO_WARNINGS 1
#endif

// Standard includes
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h> // uint16_t, uint32_t
#include <string.h> // memset(), strncpy()
#include <thread>
#include <atomic>
#include <vector>
#include <chrono>

// If using Metal, include its headers.
#ifdef USE_METAL
    #import <Metal/Metal.h>
    #import <Foundation/Foundation.h>
#endif

#ifdef _MSC_VER
    #define snprintf _snprintf
#endif

// Macros
#define VERBOSE if(gbVerbose)

// Global parameters
double    gnWorldMinX        = -2.102613; // World width = MaxX-MinX = 3.303226
double    gnWorldMaxX        =  1.200613;
double    gnWorldMinY        = -1.237710; // World height = MaxY-MinY = 2.47742 
double    gnWorldMaxY        =  1.239710;

int       gnMaxDepth         = 100; // maximum iterations
int       gnWidth            = 11520;  // image width
int       gnHeight           = 8640;   // image height
int       gnScale            = 10;     // scale factor

bool      gbAutoBrightness   = false;
int       gnGreyscaleBias    = -230;   // greyscale bias

float     gnScaleR           = 0.09f;
float     gnScaleG           = 0.11f;
float     gnScaleB           = 0.18f;

bool      gbVerbose          = false;
bool      gbSaveRawGreyscale = true;
bool      gbRotateOutput     = true;
bool      gbSaveBMP          = true;

// Calculated/Cached
uint32_t  gnImageArea        = 0; // gnWidth * gnHeight

// Output buffers
uint16_t *gpGreyscaleTexels  = NULL; // 16-bit greyscale image
uint8_t  *gpChromaticTexels  = NULL; // 24-bit RGB image

const int BUFFER_BACKSPACE   = 64;
char      gaBackspace[ BUFFER_BACKSPACE ];

char     *gpFileNameBMP      = 0; // output BMP filename override
char     *gpFileNameRAW      = 0; // output raw filename override

// Timer class for benchmarking
#ifdef _WIN32
    #define WIN32_LEAN_AND_MEAN
    #define NOMINMAX
    #include <Windows.h>
    typedef struct timeval {
        long tv_sec;
        long tv_usec;
    } timeval;

    int gettimeofday(struct timeval * tp, struct timezone * tzp)
    {
        static const uint64_t EPOCH = ((uint64_t) 116444736000000000ULL); 
        SYSTEMTIME  nSystemTime;
        FILETIME    nFileTime;
        uint64_t    nTime;
        GetSystemTime( &nSystemTime );
        SystemTimeToFileTime( &nSystemTime, &nFileTime );
        nTime = ((uint64_t)nFileTime.dwLowDateTime);
        nTime += ((uint64_t)nFileTime.dwHighDateTime) << 32;
        tp->tv_sec  = (long) ((nTime - EPOCH) / 10000000L);
        tp->tv_usec = (long) (nSystemTime.wMilliseconds * 1000);
        return 0;
    }
#else
    #include <sys/time.h>
#endif

struct DataRate
{
    char     prefix;
    uint64_t samples;
    uint64_t per_sec;
};

class Timer
{
    timeval start, end;
public:
    double   elapsed;
    uint8_t  secs;
    uint8_t  mins;
    uint8_t  hour;
    uint32_t days;
    DataRate throughput;
    char     day[ 16 ];
    char     hms[ 12 ];

    void Start() { gettimeofday( &start, NULL ); }

    void Stop() {
        gettimeofday( &end, NULL );
        elapsed = (end.tv_sec - start.tv_sec);
        size_t s = elapsed;
        secs = s % 60; s /= 60;
        mins = s % 60; s /= 60;
        hour = s % 24; s /= 24;
        days = s;
        day[0] = 0;
        if( days > 0 )
            snprintf( day, 15, "%d day%s, ", days, (days == 1) ? "" : "s" );
        sprintf( hms, "%02d:%02d:%02d", hour, mins, secs );
    }

    void Throughput( uint64_t size )
    {
        const int MAX_PREFIX = 4;
        DataRate datarate[ MAX_PREFIX ] = {
            {' ',0,0}, {'K',0,0}, {'M',0,0}, {'G',0,0}
        };
        if( !elapsed )
            return;
        int best = 0;
        for( int units = 0; units < MAX_PREFIX; units++ )
        {
            datarate[ units ].samples = size >> (10*units);
            datarate[ units ].per_sec = (uint64_t) (datarate[units].samples / elapsed);
            if (datarate[ units ].per_sec > 0)
                best = units;
        }
        throughput = datarate[ best ];
    }
};

// ---------------------------------------------------------------------------
// CPU Implementation functions (unchanged)
// ---------------------------------------------------------------------------
void AllocImageMemory( const int width, const int height )
{
    gnImageArea = width * height;
    size_t nGreyscaleBytes = gnImageArea * sizeof( uint16_t );
    gpGreyscaleTexels = (uint16_t*) malloc( nGreyscaleBytes );
    memset( gpGreyscaleTexels, 0, nGreyscaleBytes );
    size_t chromaticBytes  = gnImageArea * 3 * sizeof( uint8_t );
    gpChromaticTexels = (uint8_t*) malloc( chromaticBytes );
    memset( gpChromaticTexels, 0, chromaticBytes );
    for( int i = 0; i < (BUFFER_BACKSPACE-1); i++ )
        gaBackspace[ i ] = 8;
    gaBackspace[ BUFFER_BACKSPACE-1 ] = 0;
}

void BMP_WriteColor24bit( const char * filename, const uint8_t *texelsRGB, const int width, const int height )
{
    uint32_t headers[13];
    FILE   * pFileSave;
    int x, y, i;
    int nExtraBytes = (width * 3) % 4;
    int nPaddedSize = (width * 3 + nExtraBytes) * height;
    uint32_t nPlanes     = 1;
    uint32_t nBitcount   = 24 << 16;
    headers[0] = nPaddedSize + 54;
    headers[1] = 0;
    headers[2] = 54;
    headers[3] = 40;
    headers[4] = width;
    headers[5] = height;
    headers[6] = nBitcount | nPlanes;
    headers[7] = 0;
    headers[8] = nPaddedSize;
    headers[9] = 0;
    headers[10] = 0;
    headers[11] = 0;
    headers[12] = 0;
    pFileSave = fopen(filename, "wb");
    if( pFileSave )
    {
        fprintf(pFileSave, "BM");
        for( i = 0; i < 13; i++ )
        {
           fprintf( pFileSave, "%c", ((headers[i]) >>  0) & 0xFF );
           fprintf( pFileSave, "%c", ((headers[i]) >>  8) & 0xFF );
           fprintf( pFileSave, "%c", ((headers[i]) >> 16) & 0xFF );
           fprintf( pFileSave, "%c", ((headers[i]) >> 24) & 0xFF );
        }
        for( y = height - 1; y >= 0; y-- )
        {
            const uint8_t* scanline = &texelsRGB[ y*width*3 ];
            for( x = 0; x < width; x++ )
            {
                uint8_t r = *scanline++;
                uint8_t g = *scanline++;
                uint8_t b = *scanline++;
                fprintf( pFileSave, "%c", b );
                fprintf( pFileSave, "%c", g );
                fprintf( pFileSave, "%c", r );
           }
           if( nExtraBytes )
              for( i = 0; i < nExtraBytes; i++ )
                 fprintf( pFileSave, "%c", 0 );
        }
        fclose( pFileSave );
    }
}

uint16_t Image_Greyscale16bitMaxValue( const uint16_t *texels, const int width, const int height )
{
    const uint16_t *pSrc = texels;
    const int nLen = width * height;
    int nMax = *pSrc;
    for( int iPix = 0; iPix < nLen; iPix++ )
    {
        if( nMax < *pSrc )
            nMax = *pSrc;
        pSrc++;
    }
    return nMax;
}

void Image_Greyscale16bitRotateRight( const uint16_t *input, const int width, const int height, uint16_t *output_ )
{
    for( int y = 0; y < height; y++ )
    {
        const uint16_t *pSrc = input + (width * y);
        uint16_t *pDst = output_ + ((height-1) - y);
        for( int x = 0; x < width; x++ )
        {
            *pDst = *pSrc;
            pSrc++;
            pDst += height;
        }
    }
}

uint16_t Image_Greyscale16bitToBrightnessBias( int* bias_, float* scaleR_, float* scaleG_, float* scaleB_ )
{
    uint16_t nMaxBrightness = Image_Greyscale16bitMaxValue( gpGreyscaleTexels, gnWidth, gnHeight );
    if( gbAutoBrightness )
    {
        if( nMaxBrightness < 256)
            *bias_ = 0;
        //*bias_ = (int)(-0.045 * nMaxBrightness);
        *bias_ = (int)(-0.000001 * nMaxBrightness);
        *scaleR_ = 430.f / (float)nMaxBrightness;
        *scaleG_ = 525.f / (float)nMaxBrightness;
        *scaleB_ = 860.f / (float)nMaxBrightness;
    }
    return nMaxBrightness;
}

void Image_Greyscale16bitToColor24bit(
    const uint16_t* greyscale, const int width, const int height,
    uint8_t * chromatic_,
    const int bias, const double scaleR, const double scaleG, const double scaleB )
{
    const int nLen = width * height;
    const uint16_t *pSrc = greyscale;
    uint8_t  *pDst = chromatic_;
    for( int iPix = 0; iPix < nLen; iPix++ )
    {
        int i = *pSrc++ + bias;
        int r = (int)(i * scaleR);
        int g = (int)(i * scaleG);
        int b = (int)(i * scaleB);
        if (r > 255) r = 255; if (r < 0) r = 0;
        if (g > 255) g = 255; if (g < 0) g = 0;
        if (b > 255) b = 255; if (b < 0) b = 0;
        *pDst++ = r;
        *pDst++ = g;
        *pDst++ = b;
    }
}

char* itoaComma( size_t n, char *output_ = NULL )
{
    const size_t SIZE = 32;
    static char buffer[ SIZE ];
    char *p = buffer + SIZE - 1;
    *p-- = 0;
    while( n >= 1000 )
    {
        *p-- = '0' + (n % 10); n /= 10;
        *p-- = '0' + (n % 10); n /= 10;
        *p-- = '0' + (n % 10); n /= 10;
        *p-- = ',';
    }
    { *p-- = '0' + (n % 10); n /= 10; }
    if( n > 0) { *p-- = '0' + (n % 10); n /= 10; }
    if( n > 0) { *p-- = '0' + (n % 10); n /= 10; }
    if( output_ )
    {
        char *pEnd = buffer + SIZE - 1;
        size_t nLen = pEnd - p; 
        memcpy( output_, p+1, nLen );
    }
    return ++p;
}

void RAW_WriteGreyscale16bit( const char *filename, const uint16_t *texels, const int width, const int height )
{
    FILE *file = fopen( filename, "wb" );
    if( file )
    {
        size_t area = width * height;
        fwrite( texels, sizeof( uint16_t ), area, file );
        fclose( file );
    }
}

inline void plot( double wx, double wy, double sx, double sy, uint16_t *texels, const int width, const int height, const int maxdepth )
{
    double r = 0.0, i = 0.0, s, j;
    int u, v;
    for( int depth = 0; depth < maxdepth; depth++ )
    {
        s = (r*r - i*i) + wx;
        j = (2.0*r*i) + wy;
        r = s;
        i = j;
        if ((r*r + i*i) > 4.0)
            return;
        u = (int)((r - gnWorldMinX) * sx);
        v = (int)((i - gnWorldMinY) * sy);
        if( (u < width) && (v < height) && (u >= 0) && (v >= 0) )
            texels[ (v * width) + u ]++;
    }
}

// ---------------------------------------------------------------------------
// Metal GPU Implementation (if USE_METAL is defined)
// ---------------------------------------------------------------------------
#ifdef USE_METAL
// runBuddhabrotMetal() sets up the Metal compute pipeline, dispatches the kernel,
// copies the output back to gpGreyscaleTexels, and returns a total cell count.
int runBuddhabrotMetal() {
    // 1. Get the default Metal device.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        fprintf(stderr, "Metal is not supported on this device.\n");
        return -1;
    }
    
    // 2. Load the Metal library.
    NSError *error = nil;
    id<MTLLibrary> library = [device newDefaultLibrary];
    if (!library) {
        library = [device newLibraryWithFile:@"BuddhabrotKernel.metallib" error:&error];
        if (!library) {
            fprintf(stderr, "Failed to load Metal library: %s\n", [[error localizedDescription] UTF8String]);
            return -1;
        }
    }
    
    // 3. Get the kernel function.
    id<MTLFunction> function = [library newFunctionWithName:@"buddhabrotKernel"];
    if (!function) {
        fprintf(stderr, "Failed to load buddhabrotKernel function.\n");
        return -1;
    }
    
    // 4. Create a compute pipeline state.
    id<MTLComputePipelineState> pipelineState = [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipelineState) {
        fprintf(stderr, "Failed to create pipeline state: %s\n", [[error localizedDescription] UTF8String]);
        return -1;
    }
    
    // 5. Create a command queue.
    id<MTLCommandQueue> commandQueue = [device newCommandQueue];
    
    // 6. Allocate the GPU buffer for the output image.
    NSUInteger imageByteSize = gnImageArea * sizeof(uint32_t); // using 32-bit ints for atomics
    id<MTLBuffer> imageBuffer = [device newBufferWithLength:imageByteSize options:MTLResourceStorageModeShared];
    memset(imageBuffer.contents, 0, imageByteSize);
    
    // 7. Compute derived parameters (all as float).
    int nCol = gnWidth * gnScale;
    int nRow = gnHeight * gnScale;
    uint64_t totalThreads = (uint64_t)nCol * nRow;
    
    float nWorldW = (float)(gnWorldMaxX - gnWorldMinX);
    float nWorldH = (float)(gnWorldMaxY - gnWorldMinY);
    float dx = nWorldW / (nCol - 1.0f);
    float dy = nWorldH / (nRow - 1.0f);
    float nWorld2ImageX = (float)(gnWidth - 1) / nWorldW;
    float nWorld2ImageY = (float)(gnHeight - 1) / nWorldH;
    float fWorldMinX = (float)gnWorldMinX;
    float fWorldMinY = (float)gnWorldMinY;
    float fWorldMaxX = (float)gnWorldMaxX;
    float fWorldMaxY = (float)gnWorldMaxY;
    
    // 8. Choose a tile size (e.g., 1,000,000 threads per dispatch).
    uint64_t tileSize = 1000000;
    
    // Get maximum threads per threadgroup.
    NSUInteger maxThreadsPerThreadgroup = pipelineState.maxTotalThreadsPerThreadgroup;
    MTLSize threadgroupSize = MTLSizeMake(maxThreadsPerThreadgroup, 1, 1);
    
    // 9. Loop over the sample domain in tiles.
    auto lastUpdate = std::chrono::steady_clock::now();
    for (uint64_t baseIndex = 0; baseIndex < totalThreads; baseIndex += tileSize) {
         uint64_t currentTileSize = (totalThreads - baseIndex < tileSize) ? (totalThreads - baseIndex) : tileSize;
         MTLSize gridSize = MTLSizeMake((NSUInteger)currentTileSize, 1, 1);
         
         id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
         id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
         [encoder setComputePipelineState:pipelineState];
         
         // Set common buffers and parameters.
         [encoder setBuffer:imageBuffer offset:0 atIndex:0];
         [encoder setBytes:&gnWidth length:sizeof(gnWidth) atIndex:1];
         [encoder setBytes:&gnHeight length:sizeof(gnHeight) atIndex:2];
         [encoder setBytes:&fWorldMinX length:sizeof(fWorldMinX) atIndex:3];
         [encoder setBytes:&fWorldMinY length:sizeof(fWorldMinY) atIndex:4];
         [encoder setBytes:&fWorldMaxX length:sizeof(fWorldMaxX) atIndex:5];
         [encoder setBytes:&fWorldMaxY length:sizeof(fWorldMaxY) atIndex:6];
         [encoder setBytes:&gnMaxDepth length:sizeof(gnMaxDepth) atIndex:7];
         [encoder setBytes:&nCol length:sizeof(nCol) atIndex:8];
         [encoder setBytes:&nRow length:sizeof(nRow) atIndex:9];
         [encoder setBytes:&dx length:sizeof(dx) atIndex:10];
         [encoder setBytes:&dy length:sizeof(dy) atIndex:11];
         [encoder setBytes:&nWorld2ImageX length:sizeof(nWorld2ImageX) atIndex:12];
         [encoder setBytes:&nWorld2ImageY length:sizeof(nWorld2ImageY) atIndex:13];
         
         // Pass the 64-bit base index.
         uint64_t baseIndex64 = baseIndex;
         [encoder setBytes:&baseIndex64 length:sizeof(baseIndex64) atIndex:14];
         
         [encoder dispatchThreads:gridSize threadsPerThreadgroup:threadgroupSize];
         [encoder endEncoding];
         [commandBuffer commit];
         [commandBuffer waitUntilCompleted];
         
         // Print progress once per second.
         auto now = std::chrono::steady_clock::now();
         auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - lastUpdate).count();
         if (elapsed >= 1) {
             double progress = 100.0 * ((double)(baseIndex + currentTileSize)) / totalThreads;
             printf("Progress: %.2f%%\n", progress);
             fflush(stdout);
             lastUpdate = now;
         }
    }
    
    // 10. Copy the computed data back.
    uint32_t *tempBuffer = (uint32_t *) malloc(imageByteSize);
    if (!tempBuffer) {
        fprintf(stderr, "Failed to allocate temporary buffer.\n");
        return -1;
    }
    memcpy(tempBuffer, imageBuffer.contents, imageByteSize);
    
    // Convert from 32-bit to 16-bit.
    for (size_t i = 0; i < gnImageArea; i++) {
        gpGreyscaleTexels[i] = (uint16_t) tempBuffer[i];
    }
    free(tempBuffer);
    
    printf("Metal Buddhabrot computation complete.\n");
    return 0;
}
#endif


// ---------------------------------------------------------------------------
// Usage message
// ---------------------------------------------------------------------------
int Usage()
{
    const char *aOffOn[2] = { "OFF", "ON " };
    const char *aSaved[2] = { "SKIP", "SAVE" };
    printf(
"Buddhabrot (OMP) by Michael Pohoreski\n"
"https://github.com/Michaelangel007/buddhabrot\n"
"Usage: [width [height [depth [scale]]]]\n"
"\n"
"-?       Display usage help\n"
"-b       Use auto brightness\n"
"-bmp foo Save .BMP as filename foo\n"
"--no-bmp Don't save .BMP  (Default: %s)\n"
"--no-raw Don't save .data (Default: %s)\n"
"--no-rot Don't rotate BMP (Default: %s)\n"
"-r       Rotation output bitmap 90 degrees right\n"
"-raw foo Save raw greyscale as foo\n"
"-v       Verbose.  Display %% complete\n",
        aSaved[(int) gbSaveBMP],
        aOffOn[(int) gbRotateOutput],
        aOffOn[(int) gbSaveRawGreyscale]
    );
    return 0;
}

// ---------------------------------------------------------------------------
// main()
// ---------------------------------------------------------------------------
int main( int nArg, char * aArg[] )
{
    int iArg = 0;
    if( nArg > 1 )
    {
        while( iArg < nArg )
        {
            char *pArg = aArg[ iArg + 1 ];
            if( !pArg )
                break;
            if( pArg[0] == '-' )
            {
                iArg++;
                pArg++; // skip '-'
                if( strcmp( pArg, "--no-bmp" ) == 0 )
                    gbSaveBMP = false;
                else if( strcmp( pArg, "--no-raw" ) == 0 )
                    gbSaveRawGreyscale = false;
                else if( strcmp( pArg, "--no-rot" ) == 0 )
                    gbRotateOutput = false;
                else if( *pArg == '?' || (strcmp( pArg, "-help" ) == 0) )
                    return Usage();
                else if( *pArg == 'b' && (strcmp( pArg, "bmp") != 0) )
                    gbAutoBrightness = true;
                else if( strcmp( pArg, "bmp" ) == 0 )
                {
                    int n = iArg+1; 
                    if( n < nArg )
                    {
                        iArg++;
                        pArg = aArg[ n ];
                        gpFileNameBMP = pArg;
                        n = iArg + 1;
                        if( n < nArg )
                        {
                            pArg = aArg[ n ] - 1; 
                            *pArg = 0; 
                        }
                    }
                }
                else if( *pArg == 'r' && (strcmp( pArg, "raw") != 0) )
                    gbRotateOutput = true;
                else if( *pArg == 'v' )
                    gbVerbose = true;
                else if( strcmp( pArg, "raw" ) == 0 )
                {
                    int n = iArg+1; 
                    if( n < nArg )
                    {
                        iArg++;
                        pArg = aArg[ n ];
                        gpFileNameRAW = pArg;
                        n = iArg + 1;
                        if( n < nArg )
                        {
                            pArg = aArg[ n ] - 1; 
                            *pArg = 0; 
                        }
                    }
                }
                else
                    printf( "Unrecognized option: %c\n", *pArg ); 
            }
            else
                break;
        }
    }

    if ((iArg+1) < nArg) gnWidth    = atoi( aArg[iArg+1] );
    if ((iArg+2) < nArg) gnHeight   = atoi( aArg[iArg+2] );
    if ((iArg+3) < nArg) gnMaxDepth = atoi( aArg[iArg+3] );
    if ((iArg+4) < nArg) gnScale    = atoi( aArg[iArg+4] );

    printf( "Width: %d  Height: %d  Depth: %d  Scale: %d  RotateBMP: %d  SaveRaw: %d\n",
            gnWidth, gnHeight, gnMaxDepth, gnScale, gbRotateOutput, gbSaveRawGreyscale );

    AllocImageMemory( gnWidth, gnHeight );

    Timer stopwatch;
    stopwatch.Start();
    int nCells = 0;
#ifdef USE_METAL
    nCells = runBuddhabrotMetal();
#else
    nCells = Buddhabrot();
#endif
    stopwatch.Stop();

    VERBOSE printf( "100.00%%\n" );
    stopwatch.Throughput( nCells );
    printf( "%d %cpix/s (%d pixels, %.f seconds = %s%s)\n",
            (int)stopwatch.throughput.per_sec, stopwatch.throughput.prefix,
            nCells, stopwatch.elapsed, stopwatch.day, stopwatch.hms );

    int nMaxBrightness = Image_Greyscale16bitToBrightnessBias( &gnGreyscaleBias, &gnScaleR, &gnScaleG, &gnScaleB );
    //int nMaxBrightness = 8753;
    printf( "Max brightness: %d\n", nMaxBrightness );

    const int PATH_SIZE = 256;
    const char *pBaseName = "gpu1_buddhabrot";
    char filenameRAW[ PATH_SIZE ];
    char filenameBMP[ PATH_SIZE ];

    if( gbSaveRawGreyscale )
    {
        if( gpFileNameRAW )
            strncpy(filenameRAW, gpFileNameRAW, PATH_SIZE-1);
        else
            sprintf( filenameRAW, "raw_%s_%dx%d_d%d_s%d.u16.data",
                     pBaseName, gnWidth, gnHeight, gnMaxDepth, gnScale );
        RAW_WriteGreyscale16bit( filenameRAW, gpGreyscaleTexels, gnWidth, gnHeight );
        printf( "Saved: %s\n", filenameRAW );
    }

    uint16_t *pRotatedTexels = gpGreyscaleTexels;
    if( gbRotateOutput )
    {
        int nBytes = gnImageArea * sizeof( uint16_t );
        pRotatedTexels = (uint16_t*) malloc( nBytes );
        Image_Greyscale16bitRotateRight( gpGreyscaleTexels, gnWidth, gnHeight, pRotatedTexels );
        int t = gnWidth;
        gnWidth = gnHeight;
        gnHeight = t;
    }

    if( gbSaveBMP )
    {
        if( gpFileNameBMP )
            strncpy(filenameBMP, gpFileNameBMP, PATH_SIZE-1);
        else
            sprintf( filenameBMP, "%s_%dx%d_%d.bmp", pBaseName, gnWidth, gnHeight, gnMaxDepth );
        Image_Greyscale16bitToColor24bit( pRotatedTexels, gnWidth, gnHeight, gpChromaticTexels, gnGreyscaleBias, gnScaleR, gnScaleG, gnScaleB );
        BMP_WriteColor24bit( filenameBMP, gpChromaticTexels, gnWidth, gnHeight );
        printf( "Saved: %s\n", filenameBMP );
    }

    return 0;
}
