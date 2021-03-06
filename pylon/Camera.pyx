#!/usr/bin/env cython
# -*- coding: utf-8 -*-
# ##### BEGIN GPL LICENSE BLOCK #####
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU Lesser General Public License
#  as published by the Free Software Foundation; either version 3
#  of the License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Lesser General Public License for more details.
#
#  You should have received a copy of the GNU Lesser General Public License
#  along with this program; If not, see <http://www.gnu.org/licenses/>.
#
# ##### END GPL LICENSE BLOCK #####

__author__ = "Sergi Blanch-Torné"
__email__ = "sblanch@cells.es"
__copyright__ = "Copyright 2015, CELLS / ALBA Synchrotron"
__license__ = "GPLv3+"

import numpy as np
from Cython.Shadow import NULL
from cpython cimport PyObject
# cimport numpy as np

cdef extern from "PyCallback.h":
    cdef cppclass PyCallback:
        PyCallback(PyObject*, const char*) except+

cdef extern from "Camera.h":
    cdef cppclass CppCamera:
        CppCamera(CppFactory *factory, CppDevInfo *devInfo) except+
        bool IsCameraPresent() except+
        bool IsOpen() except+
        bool Open() except+
        bool Close() except+
        bool IsGrabbing() except+
        bool Snap(void* buffer, size_t &payload, uint32_t &w, uint32_t &h)\
            except+
        bool Start() except+
        bool Stop() except+
        bool getImage(CPylonImage *image) except+
        uint32_t GetNumStreamGrabberChannels() except+
        INode *getNextNode() except+
        INode *getNode(string name) except+
        INode *getTLNextNode() except+
        INode *getTLNode(string name) except+
        vector[PyCallback*].iterator registerRemovalCallback(PyCallback*) except+
        void deregisterRemovalCallback(vector[PyCallback*].iterator) except+

DEFAULT_HEARTBEAT = 3000  # ms
DEFAULT_READTIMEOUT = 250  # ms
DEFAULT_WRITETIMEOUT = 250  # ms

cdef class Camera(Logger):
    cdef:
        Factory _factory
        CppCamera *_camera
        __DevInfo _devInfo
        int _serial
        object _visibilityLevel
        vector[PyCallback*].iterator cbRef
        PyCallback* _cbObj
        object _wasPresent
        object _wasOpen
    _nodeNamesDict = {}
    _nodeNamesLst = []
    _nodeCategories = []
    _nodeTypes = {}
    _nodeNamesLst_tl = []

    def __init__(self, factory, *args, **kwargs):
        super(Camera, self).__init__(*args, **kwargs)
        self.name = "Camera()"
        self._debug("Void Camera Object build, "
                    "but it doesn't link with an specific camera")
        self._factory = factory
        self._visibilityLevel = Visibility()
        self._wasPresent = False
        self._wasOpen = False

    def __del__(self):
        if self.isOpen:
            self.Close()
        del self._camera

    def __str__(self):
        return "%d" % self.deviceInfo.SerialNumber

    def __repr__(self):
        return "%s (%s)" % (self.deviceInfo.SerialNumber,
                            self.deviceInfo.ModelName)

    cdef SetCppCamera(self, CppCamera* cppCamera, __DevInfo devInfo):
        self._camera = cppCamera
        self._devInfo = devInfo
        name = "Camera(%d)" % (self.deviceInfo.SerialNumber)
        self._debug("New name: %s" % name)
        self.name = name
        self._visibilityLevel.parent = self
        self._debug("CppCamera attached to a Camera (cython) object")
        self.populateNodeList()
        self._wasPresent = True
        self._heartbeat = DEFAULT_HEARTBEAT
        self._readTimeout = DEFAULT_READTIMEOUT
        self._writeTimeout = DEFAULT_WRITETIMEOUT

    property visibility:
        def __get__(self):
            return self._visibilityLevel.value

        def __set__(self, value):
            self._visibilityLevel.value = value
            self._debug("Changed node visibility")
            self._rebuildNodeList()

    def __cleanNodesDictionary(self):
        for k in self._nodeNamesDict.keys():
            self._nodeNamesDict.pop(k)

    def __cleanNodesList(self):
        while len(self._nodeNamesLst) > 0:
            self._nodeNamesLst.pop()

    # TODO: once we get full and nice access to the nodes, the objects should
    # be build asap. Having the list of node objects instead of their names
    # will improve the filtering and later access.

    # TODO: It would be better if the keys are the ICategory nodes and, within
    # each have the child nodes to have a tree structure of keys (similar view
    # than the PylonViewerApp).

    cdef populateNodeList(self):
        cdef:
            INode *node
        self.__cleanNodesDictionary()
        self.__cleanNodesList()
        self._debug("collect nodes")
        node = self._camera.getNextNode()
        while node is not NULL:
            nodeName = <string> node.GetName()
            nodeVisibility = node.GetVisibility()
            if nodeVisibility not in self._nodeNamesDict.keys():
                self._nodeNamesDict[nodeVisibility] = []
            self._nodeNamesDict[nodeVisibility].append(nodeName)
            if nodeVisibility <= self._visibilityLevel.numValue:
                if not nodeName.count('_'):
                    self._nodeNamesLst.append(nodeName)
            # check for categories and types classification
            type = InterfaceType()
            type.setParent(node)
            if type.value == 'ICategory':
                self._nodeCategories.append(nodeName)
            else:
                if type.value not in self._nodeTypes.keys():
                    self._nodeTypes[type.value] = []
                self._nodeTypes[type.value].append(nodeName)
            node = self._camera.getNextNode()
        self._nodeNamesLst.sort()
        self._nodeCategories.sort()
        for key in self._nodeTypes.keys():
            self._nodeTypes[key].sort()
        msg = "Collected "
        for v, n in [(Beginner, 'Beginner'), (Expert, 'Expert'),
                     (Guru, 'Guru')]:
            msg += "%d %s nodes, " % (len(self._nodeNamesDict[v]), n)
        self._debug(msg[:-2])
        self._debug("Build TL nodes")
        node = self._camera.getTLNextNode()
        while node is not NULL:
            nodeName = <string> node.GetName()
            self._debug("Found %s" % (nodeName))
            self._nodeNamesLst_tl.append(nodeName)
            node = self._camera.getTLNextNode()
        self._nodeNamesLst_tl.sort()

    def _rebuildNodeList(self):
        self.__cleanNodesList()
        for nodeVisibility in self._nodeNamesDict.keys():
            if nodeVisibility <= self._visibilityLevel.numValue:
                for nodeName in self._nodeNamesDict[nodeVisibility]:
                    if not nodeName.count('_'):
                        self._nodeNamesLst.append(nodeName)
        self._nodeNamesLst.sort()
        self._debug("rebuild node list, now %d elements on %s visibility"
                    % (len(self._nodeNamesLst), self._visibilityLevel.value))

    @property
    def isPresent(self):
        return <bool> (self._camera.IsCameraPresent())

    @property
    def isOpen(self):
        return <bool> (self._camera.IsOpen())

    def Open(self):
        cdef:
            bool open
        open = <bool> (self._camera.Open())
        self.registerRemovalCallback()
        self._wasOpen = True
        return open

    def Close(self):
        self.deregisterRemovalCallback()
        self._wasOpen = False
        return <bool> (self._camera.Close())

    cdef registerRemovalCallback(self):
        if self._cbObj == NULL:
            self._cbObj = new PyCallback(<PyObject*>self,
                                 <char*>"cameraRemovalCallback")
            self.cbRef = self._camera.registerRemovalCallback(self._cbObj)
            self._debug("Registered a camera removal callback")
        else:
            self._warning("Callback already registered")
 
    cdef deregisterRemovalCallback(self):
        if self._cbObj != NULL:
            self._camera.deregisterRemovalCallback(self.cbRef)
            del self._cbObj
            self._debug("Deregistered the callback for the camera removal")
        else:
            self._warning("No callback to be unregistred")
 
    cdef cameraRemovalCallback(self):
        self._warning("Camera has been removed!")
        self._wasPresent = False

    def reconnect(self):
        cdef:
            CppCamera* cppCamera
        if self.isPresent:
            self._info("Already connected with the camera")
        elif self._wasPresent:
            serial = self.deviceInfo.SerialNumber
            self._debug("Camera was present, but has been disconnected. "
                        "Proceed to search if the camera has come back")
            self._factory._refreshTlInfo()
            if serial in self._factory.serialNumbersList:
                self._factory._RecreateCamera(self, serial)
                self._info("Rebuild the CppCamera object")
                if self._wasOpen:
                    self.Open()
            else:
                self._warning("Camera not found (%s)" % self._factory.camerasList)
        else:
            self._warning("Camera wasn't present to be reconnected")

    @property
    def isGrabbing(self):
        return <bool> (self._camera.IsGrabbing())

    def Start(self):
        if not self.isOpen:
            self.Open()
        return <bool> (self._camera.Start())

    def Stop(self):
        return <bool> (self._camera.Stop())

    def getImage(self):
        cdef:
            CPylonImage *img = NULL
        self._debug("getImage()")
        if self._camera.getImage(img):
            self._debug("done getImage")
            return self.__fromBuffer(<char*> img.GetBuffer(),
                                     img.GetImageSize(),
                                     img.GetWidth(), img.GetHeight())
        return np.array([[], []], dtype=np.uint8)

    def Snap(self):
        self._debug("Snap()")
        if not self.isGrabbing:
            self._debug("It's not grabbing")
            return self.CSnap()
        return self.getImage()

        # Example:
        # import pylon
        # factory = pylon.Factory(trace=True)
        # camera = factory.getCameraBySerialNumber(...)
        # - option 1
        # import matplotlib.pyplot as plt
        # import matplotlib.cm as cm
        # plt.imshow(camera.Snap(), cmap = cm.Greys_r)
        # - option 2
        # from PIL import Image
        # img = Image.fromarray(camera.Snap(), 'L')
        # img.show()

    cdef CSnap(self):
        cdef:
            char *buffer = NULL
            size_t payloadSize
            uint32_t width, height
        self._camera.Snap(buffer, payloadSize, width, height)
        self._debug("Get Snap(): (payload %d, width %d, heigth %d)"
                    % (payloadSize, width, height))
        return self.__fromBuffer(buffer, payloadSize, width, height)

    cdef __fromBuffer(self, char *buffer, size_t payloadSize,
                      uint32_t width, uint32_t height):
        if width * height == payloadSize:
            pixelType = np.uint8
            self._debug("pixelType: 8 bits")
        elif (width * height) * 2 == payloadSize:
            pixelType = np.uint16
            self._debug("pixelType: 16 bits")
        else:
            self._debug("pixelType: unknown")
            raise BufferError("Not supported pixel type "
                              "(payload %d, width %d, heigth %d)"
                              % (payloadSize, width, height))
        self._debug("> np.frombuffer(...)")
        img_np = np.frombuffer(buffer[:payloadSize], dtype=pixelType)
        self._debug("< np.frombuffer(...)")
        img_np = img_np.reshape((height, -1))
        self._debug("np.reshape")
        img_np = img_np[:height, :width]
        self._debug("img_np 2D")
        return img_np

    @property
    def deviceInfo(self):
        return self._devInfo

    @property
    def nStreamGrabbers(self):
        return int(self._camera.GetNumStreamGrabberChannels())

    # dictionary behaviour for the nodes
    def keys(self):
        return self._nodeNamesLst[:]

    def categories(self):
        return self._nodeCategories[:]

    def tlNodes(self):
        '''returns a list of Transport Layer nodes.
        '''
        return self._nodeNamesLst_tl[:]

    def tlNode(self, name):
        '''Given a Transport Layer node name, return the requested node
        '''
        if name in self._nodeNamesLst_tl:
            node = Node()
            node.setINode(self._buildTLNode(name))
            return node
        return None

    property _heartbeat:
        def __get__(self):
            return self.tlNode('HeartbeatTimeout').value
 
        def __set__(self, value):
            if type(value) in [int, long] and value > 0:
                try:
                    currentValue = self.tlNode('HeartbeatTimeout').value
                    self._debug("Modify the HeartbeatTimeout from %d to %d"
                                % (currentValue, value))
                    self.tlNode('HeartbeatTimeout').value = value
                except Exception as e:
                    self._warning("Cannot modify HeartbeatTimeout")

    property _readTimeout:
        def __get__(self):
            return self.tlNode('ReadTimeout').value
 
        def __set__(self, value):
            if type(value) in [int, long] and value > 0:
                try:
                    currentValue = self.tlNode('ReadTimeout').value
                    self._debug("Modify the ReadTimeout from %d to %d"
                                % (currentValue, value))
                    self.tlNode('ReadTimeout').value = value
                except Exception as e:
                    self._warning("Cannot modify ReadTimeout")

    property _writeTimeout:
        def __get__(self):
            return self.tlNode('WriteTimeout').value
 
        def __set__(self, value):
            if type(value) in [int, long] and value > 0:
                try:
                    currentValue = self.tlNode('WriteTimeout').value
                    self._debug("Modify the WriteTimeout from %d to %d"
                                % (currentValue, value))
                    self.tlNode('WriteTimeout').value = value
                except Exception as e:
                    self._warning("Cannot modify WriteTimeout")

    def types(self):
        return self._nodeTypes.keys()

    cdef INode* _buildNode(self, name):
        return self._camera.getNode(<string> name)

    cdef INode* _buildTLNode(self, name):
        return self._camera.getTLNode(<string> name)

    def __getitem__(self, key):
        if key in self._nodeCategories or key in self._nodeNamesLst:
            node = Node()
            node.setINode(self._buildNode(key))
            return node
        for nodeVisibility in self._nodeNamesDict.keys():
            if nodeVisibility <= self._visibilityLevel.numValue and \
                    key in self._nodeNamesDict[nodeVisibility]:
                node = Node()
                node.setINode(self._buildNode(key))
                return node
        return None

    def __setitem__(self, key, value):
        if key in self._nodeNamesLst:
            item = self.__getitem__(key)
            item.value = value
