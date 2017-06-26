Electron density map processing
===============================
I suddenly got obsessed by the data available in EBI EMDB, this is the result.

Idea for visualizing using WebGL
--------------------------------
1. Stream CCP4 file into program
2. Decode GZIP in chunks
3. Buffer and read CCP4 header
4. Buffer and read symmetry operations
5. Process density values directly using marching cubes algorithm
   and using contour value supplied by author (retrieve via JSON API)
6. Real time updating and of the polygon array

Rendering might have decent performance. However, this operation might take very
long for large maps (limited by the download speed, so it could easily take 10
minutes for large files). But in exchange you get a beautiful surface contour!
Also, since the pipeline is streamed, and most data is destructed at the end
(by directly processing it), large maps can be handled on mediocre machines.

Idea for decentralized caching processed visualizations
-------------------------------------------------------
So we have no resources to set up a central server. But how cool would it be if
all the client-side computed contour meshes could be shared? Well, there is, a
way. Even though this is not the most elegant solution, one way to do this is to
use GitHub Gist to store the computed mesh (Base64 encoded for example) under an
anonymous user. Then we need a secondary system to resolve EMDB IDs to the Gist
URL. For this we can use a URL shortener that allows a custom alias, and that
has API access. It is possible to use https://hiveam.com for this. This even
gives us usage analytics! (but we have to include a API key :-/). We put the
EMDB ID in the custom alias so that we can later try this URL to discover
a Gist that has a pre-computed mesh! If we use a long prefix, the changes of
the system failing is relatively small (unless it is done deliberately).
