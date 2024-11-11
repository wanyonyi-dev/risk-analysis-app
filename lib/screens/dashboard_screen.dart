import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'package:local_auth/local_auth.dart';
import 'package:intl/intl.dart';
import 'dart:convert';

class DashboardScreen extends StatefulWidget {
  @override
  _DashboardScreenState createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  StreamSubscription<DocumentSnapshot>? _securityScoreSubscription;
  StreamSubscription<QuerySnapshot>? _threatSubscription;
  StreamSubscription<QuerySnapshot>? _activitySubscription;

  double secureScore = 0;
  double riskScore = 0;
  List<Map<String, dynamic>> threatCategories = [];
  List<Map<String, dynamic>> recentActivity = [];
  List<Map<String, dynamic>> recommendations = [];
  bool isScanning = false;
  Timer? _scanTimer;

  @override
  void initState() {
    super.initState();
    _initializeFirestoreListeners();
    _loadInitialData();
  }

  void _initializeFirestoreListeners() {
    _securityScoreSubscription = _firestore
        .collection('security_metrics')
        .doc('current')
        .snapshots()
        .listen((DocumentSnapshot snapshot) {
      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>;
        setState(() {
          secureScore = (data['secure_score'] ?? 0).toDouble();
          riskScore = (data['risk_score'] ?? 0).toDouble();
        });
      }
    });

    _threatSubscription = _firestore
        .collection('threats')
        .snapshots()
        .listen((QuerySnapshot snapshot) {
      setState(() {
        threatCategories = snapshot.docs
            .map((doc) => Map<String, dynamic>.from(doc.data() as Map))
            .toList();
      });
    });

    _activitySubscription = _firestore
        .collection('activity')
        .orderBy('timestamp', descending: true)
        .limit(10)
        .snapshots()
        .listen((QuerySnapshot snapshot) {
      setState(() {
        recentActivity = snapshot.docs
            .map((doc) => Map<String, dynamic>.from(doc.data() as Map))
            .toList();
      });
    });
  }

  Future<void> _loadInitialData() async {
    try {
      final recommendationsSnapshot = await _firestore
          .collection('recommendations')
          .get();

      setState(() {
        recommendations = recommendationsSnapshot.docs
            .map((doc) => Map<String, dynamic>.from(doc.data()))
            .toList();
      });

      if (recommendations.isEmpty) {
        await _initializeDefaultData();
      }
    } catch (e) {
      print('Error loading initial data: $e');
    }
  }

  Future<void> _initializeDefaultData() async {
    final batch = _firestore.batch();

    batch.set(_firestore.collection('security_metrics').doc('current'), {
      'secure_score': 75,
      'risk_score': 25,
      'last_updated': FieldValue.serverTimestamp(),
    });

    final threatsRef = _firestore.collection('threats');
    batch.set(threatsRef.doc('threat1'), {
      'title': 'Malware Protection',
      'level': 'medium',
      'type': 'application',
    });
    batch.set(threatsRef.doc('threat2'), {
      'title': 'Network Security',
      'level': 'low',
      'type': 'network',
    });

    batch.set(_firestore.collection('recommendations').doc('rec1'), {
      'title': 'Update System',
      'description': 'Your system needs security updates',
      'type': 'system_update',
      'priority': 'high',
    });

    await batch.commit();
  }

  Future<void> _startSecurityScan() async {
    if (isScanning) return;

    setState(() {
      isScanning = true;
    });

    try {
      await Permission.location.request();
      await Permission.storage.request();

      final deviceInfo = DeviceInfoPlugin();
      final networkInfo = NetworkInfo();

      final scanRef = _firestore.collection('scans').doc();
      final scanId = scanRef.id;

      _scanTimer = Timer.periodic(Duration(seconds: 2), (timer) async {
        try {
          final androidInfo = await deviceInfo.androidInfo;
          final wifiName = await networkInfo.getWifiName();

          final securityChecks = {
            'device_encrypted': androidInfo.isDeviceSecure,
            'sdk_version': androidInfo.version.sdkInt,
            'security_patch': androidInfo.version.securityPatch,
            'network_name': wifiName,
            'timestamp': FieldValue.serverTimestamp(),
          };

          await scanRef.set(securityChecks, SetOptions(merge: true));

          await _firestore.collection('activity').add({
            'title': 'Security Scan in Progress',
            'time': FieldValue.serverTimestamp(),
            'type': 'scan',
            'details': securityChecks,
          });

          if (timer.tick >= 5) {
            timer.cancel();
            setState(() {
              isScanning = false;
            });

            await scanRef.set({
              'status': 'completed',
              'completion_time': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));

            _generateRecommendations(securityChecks);
          }
        } catch (e) {
          print('Scan error: $e');
          timer.cancel();
          setState(() {
            isScanning = false;
          });
        }
      });
    } catch (e) {
      print('Error starting scan: $e');
      setState(() {
        isScanning = false;
      });
    }
  }

  Future<void> _generateRecommendations(Map<String, dynamic> securityChecks) async {
    try {
      final recommendations = <Map<String, dynamic>>[];

      if (securityChecks['sdk_version'] < 29) {
        recommendations.add({
          'title': 'System Update Required',
          'description': 'Your Android version is outdated and may have security vulnerabilities',
          'priority': 'high',
          'type': 'system_update',
          'timestamp': FieldValue.serverTimestamp(),
        });
      }

      if (!securityChecks['device_encrypted']) {
        recommendations.add({
          'title': 'Enable Device Encryption',
          'description': 'Your device is not encrypted. Enable encryption to protect your data',
          'priority': 'high',
          'type': 'encryption',
          'timestamp': FieldValue.serverTimestamp(),
        });
      }

      final batch = _firestore.batch();
      for (final recommendation in recommendations) {
        final docRef = _firestore.collection('recommendations').doc();
        batch.set(docRef, recommendation);
      }
      await batch.commit();
    } catch (e) {
      print('Error generating recommendations: $e');
    }
  }

  Widget _buildSecurityScoreCard() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Security Score',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: PieChart(
                PieChartData(
                  sections: [
                    PieChartSectionData(
                      value: secureScore,
                      color: Colors.green,
                      title: '${secureScore.round()}%',
                      radius: 60,
                    ),
                    PieChartSectionData(
                      value: riskScore,
                      color: Colors.red,
                      title: '${riskScore.round()}%',
                      radius: 60,
                    ),
                  ],
                  sectionsSpace: 2,
                  centerSpaceRadius: 40,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThreatsList() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Active Threats',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 16),
            ListView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: threatCategories.length,
              itemBuilder: (context, index) {
                final threat = threatCategories[index];
                return ListTile(
                  leading: Icon(
                    _getThreatIcon(threat['type']),
                    color: _getThreatColor(threat['level']),
                  ),
                  title: Text(threat['title']),
                  subtitle: Text('Risk Level: ${threat['level']}'),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentActivity() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent Activity',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 16),
            ListView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: recentActivity.length,
              itemBuilder: (context, index) {
                final activity = recentActivity[index];
                return ListTile(
                  leading: Icon(_getActivityIcon(activity['type'])),
                  title: Text(activity['title']),
                  subtitle: Text(
                    _formatTimestamp(activity['time']),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecommendations() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Security Recommendations',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 16),
            ListView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: recommendations.length,
              itemBuilder: (context, index) {
                final recommendation = recommendations[index];
                return ListTile(
                  leading: Icon(
                    _getPriorityIcon(recommendation['priority']),
                    color: _getPriorityColor(recommendation['priority']),
                  ),
                  title: Text(recommendation['title']),
                  subtitle: Text(recommendation['description']),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  IconData _getThreatIcon(String type) {
    switch (type) {
      case 'application':
        return Icons.apps;
      case 'network':
        return Icons.wifi;
      default:
        return Icons.security;
    }
  }

  Color _getThreatColor(String level) {
    switch (level) {
      case 'high':
        return Colors.red;
      case 'medium':
        return Colors.orange;
      case 'low':
        return Colors.yellow;
      default:
        return Colors.grey;
    }
  }

  IconData _getActivityIcon(String type) {
    switch (type) {
      case 'scan':
        return Icons.search;
      case 'threat':
        return Icons.warning;
      case 'update':
        return Icons.system_update;
      default:
        return Icons.info;
    }
  }

  IconData _getPriorityIcon(String priority) {
    switch (priority) {
      case 'high':
        return Icons.priority_high;
      case 'medium':
        return Icons.warning;
      case 'low':
        return Icons.info;
      default:
        return Icons.info;
    }
  }

  Color _getPriorityColor(String priority) {
    switch (priority) {
      case 'high':
        return Colors.red;
      case 'medium':
        return Colors.orange;
      case 'low':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  String _formatTimestamp(Timestamp? timestamp) {
    if (timestamp == null) return '';
    return DateFormat.yMd().add_jm().format(timestamp.toDate());
  }

  @override
  void dispose() {
    _securityScoreSubscription?.cancel();
    _threatSubscription?.cancel();
    _activitySubscription?.cancel();
    _scanTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Security Dashboard'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _loadInitialData,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadInitialData,
        child: SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSecurityScoreCard(),
              SizedBox(height: 16),
              _buildThreatsList(),
              SizedBox(height: 16),
              _buildRecentActivity(),
              SizedBox(height: 16),
              _buildRecommendations(),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startSecurityScan,
        label: Text(isScanning ? 'Scanning...' : 'Start Scan'),
        icon: Icon(isScanning ? Icons.stop : Icons.security),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'Activity',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

extension on AndroidDeviceInfo {
  get isDeviceSecure => null;
}

// Settings Screen
class SettingsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Security Settings'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(Icons.notifications),
            title: Text('Notifications'),
            subtitle: Text('Configure security alerts'),
            onTap: () {
              // Implement notification settings
            },
          ),
          ListTile(
            leading: Icon(Icons.schedule),
            title: Text('Scan Schedule'),
            subtitle: Text('Set automatic scan frequency'),
            onTap: () {
              // Implement scan schedule settings
            },
          ),
          ListTile(
            leading: Icon(Icons.security),
            title: Text('Security Preferences'),
            subtitle: Text('Customize security rules'),
            onTap: () {
              // Implement security preferences
            },
          ),
          Divider(),
          ListTile(
            leading: Icon(Icons.info),
            title: Text('About'),
            subtitle: Text('Version 1.0.0'),
            onTap: () {
              // Show about dialog
              showAboutDialog(
                context: context,
                applicationName: 'Security Dashboard',
                applicationVersion: '1.0.0',
                applicationLegalese: '© 2024 Your Company',
              );
            },
          ),
        ],
      ),
    );
  }
}

// Activity History Screen
class ActivityHistoryScreen extends StatelessWidget {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Activity History'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('activity')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          final activities = snapshot.data?.docs ?? [];

          return ListView.builder(
            itemCount: activities.length,
            itemBuilder: (context, index) {
              final activity = activities[index].data() as Map<String, dynamic>;
              return Card(
                margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  leading: Icon(_getActivityTypeIcon(activity['type'])),
                  title: Text(activity['title']),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_formatTimestamp(activity['timestamp'] as Timestamp)),
                      if (activity['details'] != null)
                        Text(
                          activity['details'].toString(),
                          style: TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                  onTap: () {
                    _showActivityDetails(context, activity);
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  IconData _getActivityTypeIcon(String type) {
    switch (type) {
      case 'scan':
        return Icons.security;
      case 'threat':
        return Icons.warning;
      case 'update':
        return Icons.system_update;
      default:
        return Icons.info;
    }
  }

  String _formatTimestamp(Timestamp timestamp) {
    return DateFormat.yMMMd().add_jm().format(timestamp.toDate());
  }

  void _showActivityDetails(BuildContext context, Map<String, dynamic> activity) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(activity['title']),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Time: ${_formatTimestamp(activity['timestamp'] as Timestamp)}'),
              SizedBox(height: 8),
              Text('Type: ${activity['type']}'),
              if (activity['details'] != null) ...[
                SizedBox(height: 8),
                Text('Details:'),
                SizedBox(height: 4),
                Text(
                  JsonEncoder.withIndent('  ')
                      .convert(activity['details']),
                  style: TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }
}

// Main App
class SecurityDashboardApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Security Dashboard',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: DashboardScreen(),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(SecurityDashboardApp());
}